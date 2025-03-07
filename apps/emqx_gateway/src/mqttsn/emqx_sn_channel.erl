%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_sn_channel).

-behaviour(emqx_gateway_channel).

-include("src/mqttsn/include/emqx_sn.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("emqx/include/logger.hrl").

%% API
-export([ info/1
        , info/2
        , stats/1
        ]).

-export([ init/2
        , handle_in/2
        , handle_out/3
        , handle_deliver/2
        , handle_timeout/3
        , terminate/2
        , set_conn_state/2
        ]).

-export([ handle_call/3
        , handle_cast/2
        , handle_info/2
        ]).

-record(channel, {
          %% Context
          ctx           :: emqx_gateway_ctx:context(),
          %% Registry
          registry      :: emqx_sn_registry:registry(),
          %% Gateway Id
          gateway_id    :: integer(),
          %% Enable QoS3
          enable_qos3   :: boolean(),   %% XXX: Get confs from ctx ?
          %% MQTT-SN Connection Info
          conninfo      :: emqx_types:conninfo(),
          %% MQTT-SN Client Info
          clientinfo    :: emqx_types:clientinfo(),
          %% Session
          session       :: emqx_session:session() | undefined,
          %% Keepalive
          keepalive     :: emqx_keepalive:keepalive() | undefined,
          %% Will Msg
          will_msg      :: emqx_types:message() | undefined,
          %% ClientInfo override specs
          clientinfo_override :: map(),
          %% Connection State
          conn_state    :: conn_state(),
          %% Timer
          timers :: #{atom() => disable | undefined | reference()},
          %%% Takeover
          takeover :: boolean(),
          %% Resume
          resuming :: boolean(),
          %% Pending delivers when takeovering
          pendings :: list()
         }).

-type(channel() :: #channel{}).

-type(conn_state() :: idle | connecting | connected | asleep | disconnected).

-type(reply() :: {outgoing, mqtt_sn_message()}
               | {outgoing, [mqtt_sn_message()]}
               | {event, conn_state()|updated}
               | {close, Reason :: atom()}).

-type(replies() :: reply() | [reply()]).

-define(TIMER_TABLE, #{
          alive_timer  => keepalive,
          retry_timer  => retry_delivery,
          await_timer  => expire_awaiting_rel,
          asleep_timer => expire_asleep
         }).

-define(DEFAULT_OVERRIDE,
        #{ clientid => <<"${ConnInfo.clientid}">>
         %, username => <<"${ConnInfo.clientid}">>
         %, password => <<"${Packet.headers.passcode}">>
         }).

-define(INFO_KEYS, [conninfo, conn_state, clientinfo, session, will_msg]).

-define(NEG_QOS_CLIENT_ID, <<"NegQoS-Client">>).

%%--------------------------------------------------------------------
%% Init the channel
%%--------------------------------------------------------------------

%% @doc Init protocol
init(ConnInfo = #{peername := {PeerHost, _},
                  sockname := {_, SockPort}}, Option) ->
    Peercert = maps:get(peercert, ConnInfo, undefined),
    Mountpoint = maps:get(mountpoint, Option, undefined),
    Registry = maps:get(registry, Option),
    GwId = maps:get(gateway_id, Option),
    EnableQoS3 = maps:get(enable_qos3, Option, true),
    ListenerId = case maps:get(listener, Option, undefined) of
                     undefined -> undefined;
                     {GwName, Type, LisName} ->
                         emqx_gateway_utils:listener_id(GwName, Type, LisName)
                 end,
    ClientInfo = set_peercert_infos(
                   Peercert,
                   #{ zone => default
                    , listener => ListenerId
                    , protocol => 'mqtt-sn'
                    , peerhost => PeerHost
                    , sockport => SockPort
                    , clientid => undefined
                    , username => undefined
                    , is_bridge => false
                    , is_superuser => false
                    , mountpoint => Mountpoint
                    }
                  ),

    Ctx = maps:get(ctx, Option),
    Override = maps:merge(?DEFAULT_OVERRIDE,
                          maps:get(clientinfo_override, Option, #{})
                         ),
	#channel{ ctx = Ctx
            , registry = Registry
            , gateway_id = GwId
            , enable_qos3 = EnableQoS3
            , conninfo = ConnInfo
            , clientinfo = ClientInfo
            , clientinfo_override = Override
            , conn_state = idle
            , timers = #{}
            , takeover = false
            , resuming = false
            , pendings = []
            }.

set_peercert_infos(NoSSL, ClientInfo)
  when NoSSL =:= nossl;
       NoSSL =:= undefined ->
    ClientInfo;
set_peercert_infos(Peercert, ClientInfo) ->
    {DN, CN} = {esockd_peercert:subject(Peercert),
                esockd_peercert:common_name(Peercert)},
    ClientInfo#{dn => DN, cn => CN}.

-spec info(channel()) -> emqx_types:infos().
info(Channel) ->
    maps:from_list(info(?INFO_KEYS, Channel)).

-spec info(list(atom())|atom(), channel()) -> term().
info(Keys, Channel) when is_list(Keys) ->
    [{Key, info(Key, Channel)} || Key <- Keys];

info(conninfo, #channel{conninfo = ConnInfo}) ->
    ConnInfo;
info(conn_state, #channel{conn_state = ConnState}) ->
    ConnState;
info(clientinfo, #channel{clientinfo = ClientInfo}) ->
    ClientInfo;
info(session, #channel{session = Session}) ->
    emqx_misc:maybe_apply(fun emqx_session:info/1, Session);
info(will_msg, #channel{will_msg = WillMsg}) ->
    WillMsg;
info(clientid, #channel{clientinfo = #{clientid := ClientId}}) ->
    ClientId;
info(ctx, #channel{ctx = Ctx}) ->
    Ctx.

-spec(stats(channel()) -> emqx_types:stats()).
stats(#channel{session = undefined})->
    [];
stats(#channel{session = Session})->
    emqx_session:stats(Session).

set_conn_state(ConnState, Channel) ->
    Channel#channel{conn_state = ConnState}.

enrich_conninfo(?SN_CONNECT_MSG(_Flags, _ProtoId, Duration, ClientId),
                Channel = #channel{conninfo = ConnInfo}) ->
    NConnInfo = ConnInfo#{ clientid => ClientId
                         , proto_name => <<"MQTT-SN">>
                         , proto_ver => <<"1.2">>
                         , clean_start => true
                         , keepalive => Duration
                         , expiry_interval => 0
                         },
    {ok, Channel#channel{conninfo = NConnInfo}}.

run_conn_hooks(Packet, Channel = #channel{ctx = Ctx,
                                          conninfo = ConnInfo}) ->
    %% XXX: Assign headers of Packet to ConnProps
    ConnProps = #{},
    case run_hooks(Ctx, 'client.connect', [ConnInfo], ConnProps) of
        Error = {error, _Reason} -> Error;
        _NConnProps ->
            {ok, Packet, Channel}
    end.

enrich_clientinfo(Packet,
                  Channel = #channel{
                               conninfo = ConnInfo,
                               clientinfo = ClientInfo0,
                               clientinfo_override = Override}) ->
    ClientInfo = write_clientinfo(
                   feedvar(Override, Packet, ConnInfo, ClientInfo0),
                   ClientInfo0
                  ),
    {ok, NPacket, NClientInfo} = emqx_misc:pipeline(
                                   [ fun maybe_assign_clientid/2
                                   %% FIXME: CALL After authentication successfully
                                   , fun fix_mountpoint/2
                                   ], Packet, ClientInfo
                                  ),
    {ok, NPacket, Channel#channel{clientinfo = NClientInfo}}.

feedvar(Override, Packet, ConnInfo, ClientInfo) ->
    Envs = #{ 'ConnInfo' => ConnInfo
            , 'ClientInfo' => ClientInfo
            , 'Packet' => connect_packet_to_map(Packet)
            },
    maps:map(fun(_K, V) ->
        Tokens = emqx_plugin_libs_rule:preproc_tmpl(V),
        emqx_plugin_libs_rule:proc_tmpl(Tokens, Envs)
    end, Override).

connect_packet_to_map(#mqtt_sn_message{}) ->
    %% XXX: Empty now
    #{}.

write_clientinfo(Override, ClientInfo) ->
    Override1 = maps:with([username, password, clientid], Override),
    maps:merge(ClientInfo, Override1).

maybe_assign_clientid(_Packet, ClientInfo = #{clientid := ClientId})
    when ClientId == undefined;
         ClientId == <<>> ->
    {ok, ClientInfo#{clientid => emqx_guid:to_base62(emqx_guid:gen())}};

maybe_assign_clientid(_Packet, ClientInfo) ->
    {ok, ClientInfo}.

fix_mountpoint(_Packet, #{mountpoint := undefined}) -> ok;
fix_mountpoint(_Packet, ClientInfo = #{mountpoint := Mountpoint}) ->
    %% TODO: Enrich the varibale replacement????
    %%       i.e: ${ClientInfo.auth_result.productKey}
    Mountpoint1 = emqx_mountpoint:replvar(Mountpoint, ClientInfo),
    {ok, ClientInfo#{mountpoint := Mountpoint1}}.

set_log_meta(_Packet, #channel{clientinfo = #{clientid := ClientId}}) ->
    emqx_logger:set_metadata_clientid(ClientId),
    ok.

maybe_require_will_msg(?SN_CONNECT_MSG(Flags, _, _, _), Channel) ->
    #mqtt_sn_flags{will = Will} = Flags,
    case Will of
        true ->
            {error, need_will_msg, Channel};
        _ ->
            ok
    end.

auth_connect(_Packet, Channel = #channel{ctx = Ctx,
                                         clientinfo = ClientInfo}) ->
    #{clientid := ClientId,
      username := Username} = ClientInfo,
    case emqx_gateway_ctx:authenticate(Ctx, ClientInfo) of
        {ok, NClientInfo} ->
            {ok, Channel#channel{clientinfo = NClientInfo}};
        {error, Reason} ->
            ?SLOG(warning, #{ msg => "client_login_failed"
                            , clientid => ClientId
                            , username => Username
                            , reason => Reason
                            }),
            %% FIXME: ReasonCode?
            {error, Reason}
    end.

ensure_connected(Channel = #channel{
                              ctx = Ctx,
                              conninfo = ConnInfo,
                              clientinfo = ClientInfo}) ->
    NConnInfo = ConnInfo#{connected_at => erlang:system_time(millisecond)},
    ok = run_hooks(Ctx, 'client.connected', [ClientInfo, NConnInfo]),
    Channel#channel{conninfo = NConnInfo,
                    conn_state = connected
                   }.

process_connect(Channel = #channel{
                           ctx = Ctx,
                           conninfo = ConnInfo,
                           clientinfo = ClientInfo
                          }) ->
    SessFun = fun(_,_) -> emqx_session:init(#{max_inflight => 1}) end,
    case emqx_gateway_ctx:open_session(
           Ctx,
           true,
           ClientInfo,
           ConnInfo,
           SessFun
          ) of
        {ok, #{session := Session,
               present := _Present}} ->
            handle_out(connack, ?SN_RC_ACCEPTED,
                       Channel#channel{session = Session});
        {error, Reason} ->
            ?SLOG(error, #{ msg => "failed_to_open_session"
                          , reason => Reason
                          }),
            handle_out(connack, ?SN_RC_FAILED_SESSION, Channel)
    end.

%%--------------------------------------------------------------------
%% Enrich Keepalive

ensure_keepalive(Channel = #channel{conninfo = ConnInfo}) ->
    ensure_keepalive_timer(maps:get(keepalive, ConnInfo), Channel).

ensure_keepalive_timer(0, Channel) -> Channel;
ensure_keepalive_timer(Interval, Channel) ->
    Keepalive = emqx_keepalive:init(round(timer:seconds(Interval))),
    ensure_timer(alive_timer, Channel#channel{keepalive = Keepalive}).

%%--------------------------------------------------------------------
%% Handle incoming packet
%%--------------------------------------------------------------------

-spec handle_in(emqx_types:packet() | {frame_error, any()}, channel())
      -> {ok, channel()}
       | {ok, replies(), channel()}
       | {shutdown, Reason :: term(), channel()}
       | {shutdown, Reason :: term(), replies(), channel()}.

%% SEARCHGW, GWINFO
handle_in(?SN_SEARCHGW_MSG(_Radius),
          Channel = #channel{gateway_id = GwId}) ->
    {ok, {outgoing, ?SN_GWINFO_MSG(GwId, <<>>)}, Channel};

handle_in(?SN_ADVERTISE_MSG(_GwId, _Radius), Channel) ->
    % ingore
    shutdown(normal, Channel);

handle_in(?SN_PUBLISH_MSG(#mqtt_sn_flags{qos = ?QOS_NEG1,
                                         topic_id_type = TopicIdType
                                        },
                         TopicId, _MsgId, Data),
         Channel = #channel{conn_state = idle, registry = Registry}) ->
    %% FIXME: check enable_qos3 ??
    TopicName = case (TopicIdType =:= ?SN_SHORT_TOPIC) of
                    true ->
                        <<TopicId:16>>;
                    false ->
                        emqx_sn_registry:lookup_topic(
                          Registry,
                          ?NEG_QOS_CLIENT_ID,
                          TopicId
                         )
                end,
    _ = case TopicName =/= undefined of
        true ->
            Msg = emqx_message:make(
                    ?NEG_QOS_CLIENT_ID,
                    ?QOS_0,
                    TopicName,
                    Data
                   ),
            emqx_broker:publish(Msg);
        false ->
            ok
    end,
    ?SLOG(debug, #{ msg => "receive_qo3_message_in_idle_mode"
                  , topic => TopicName
                  , data => Data
                  }),
    {ok, Channel};

handle_in(Pkt = #mqtt_sn_message{type = Type},
          Channel = #channel{conn_state = idle})
  when Type /= ?SN_CONNECT ->
    ?SLOG(warning, #{ msg => "receive_unknown_packet_in_idle_state"
                    , packet => Pkt
                    }),
    shutdown(normal, Channel);

handle_in(?SN_CONNECT_MSG(_Flags, _ProtoId, _Duration, _ClientId),
          Channel = #channel{conn_state = connecting}) ->
    ?SLOG(warning, #{ msg => "receive_connect_packet_in_connecting_state"
                    }),
    {ok, Channel};

handle_in(?SN_CONNECT_MSG(_Flags, _ProtoId, _Duration, _ClientId),
          Channel = #channel{conn_state = connected}) ->
    {error, unexpected_connect, Channel};

handle_in(?SN_WILLTOPIC_EMPTY_MSG,
          Channel = #channel{conn_state = connecting}) ->
    %% 6.3:
    %% Note that if a client wants to delete only its Will data at
    %% connection setup, it could send a CONNECT message with
    %% 'CleanSession=false' and 'Will=true',
    %% and sends an empty WILLTOPIC message to the GW when prompted to do so
    case auth_connect(fake_packet, Channel#channel{will_msg = undefined}) of
        {ok, NChannel} ->
            process_connect(ensure_connected(NChannel));
        {error, ReasonCode} ->
            handle_out(connack, ReasonCode, Channel)
    end;

handle_in(?SN_WILLTOPIC_MSG(Flags, Topic),
          Channel = #channel{conn_state = connecting,
                             clientinfo = #{clientid := ClientId}}) ->
    #mqtt_sn_flags{qos = QoS, retain = Retain} = Flags,
    WillMsg0 = emqx_message:make(ClientId, QoS, Topic, <<>>),
    WillMsg = emqx_message:set_flag(retain, Retain, WillMsg0),
    NChannel = Channel#channel{will_msg = WillMsg},
    {ok, {outgoing, ?SN_WILLMSGREQ_MSG()}, NChannel};

handle_in(?SN_WILLMSG_MSG(Payload),
          Channel = #channel{conn_state = connecting,
                             will_msg = WillMsg}) ->
    NWillMsg = WillMsg#message{payload = Payload},
    case auth_connect(fake_packet, Channel#channel{will_msg = NWillMsg}) of
        {ok, NChannel} ->
            process_connect(ensure_connected(NChannel));
        {error, ReasonCode} ->
            handle_out(connack, ReasonCode, Channel)
    end;

handle_in(Packet = ?SN_CONNECT_MSG(_Flags, _ProtoId, _Duration, _ClientId),
          Channel) ->
    case emqx_misc:pipeline(
           [ fun enrich_conninfo/2
           , fun run_conn_hooks/2
           , fun enrich_clientinfo/2
           , fun set_log_meta/2
           %% TODO: How to implement the banned in the gateway instance?
           %, fun check_banned/2
           , fun maybe_require_will_msg/2
           , fun auth_connect/2
           ], Packet, Channel#channel{conn_state = connecting}) of
        {ok, _NPacket, NChannel} ->
            process_connect(ensure_connected(NChannel));
        {error, need_will_msg, NChannel} ->
            {ok, {outgoing, ?SN_WILLTOPICREQ_MSG()}, NChannel};
        {error, ReasonCode, NChannel} ->
            handle_out(connack, ReasonCode, NChannel)
    end;

handle_in(?SN_REGISTER_MSG(_TopicId, MsgId, TopicName),
          Channel = #channel{registry = Registry,
                             clientinfo = #{clientid := ClientId}}) ->
    case emqx_sn_registry:register_topic(Registry, ClientId, TopicName) of
        TopicId when is_integer(TopicId) ->
            ?SLOG(debug, #{ msg => "registered_topic_name"
                          , topic_name => TopicName
                          , topic_id => TopicId
                          }),
            AckPacket = ?SN_REGACK_MSG(TopicId, MsgId, ?SN_RC_ACCEPTED),
            {ok, {outgoing, AckPacket}, Channel};
        {error, too_large} ->
            ?SLOG(error, #{ msg => "register_topic_failed"
                          , topic_name => TopicName
                          , reason => topic_id_fulled
                          }),
            AckPacket = ?SN_REGACK_MSG(
                           ?SN_INVALID_TOPIC_ID,
                           MsgId,
                           ?SN_RC_NOT_SUPPORTED
                          ),
            {ok, {outgoing, AckPacket}, Channel};
        {error, wildcard_topic} ->
            ?SLOG(error, #{ msg => "register_topic_failed"
                          , topic_name => TopicName
                          , reason => not_support_wildcard_topic
                          }),
            AckPacket = ?SN_REGACK_MSG(
                           ?SN_INVALID_TOPIC_ID,
                           MsgId,
                           ?SN_RC_NOT_SUPPORTED
                          ),
            {ok, {outgoing, AckPacket}, Channel}
    end;

handle_in(PubPkt = ?SN_PUBLISH_MSG(_Flags, TopicId0, MsgId, _Data), Channel) ->
    TopicId = case is_integer(TopicId0) of
                  true -> TopicId0;
                  _ -> <<Id:16>> = TopicId0, Id
              end,
    case emqx_misc:pipeline(
          [ fun check_qos3_enable/2
          , fun preproc_pub_pkt/2
          , fun convert_topic_id_to_name/2
          , fun check_pub_authz/2
          , fun convert_pub_to_msg/2
          ], PubPkt, Channel) of
        {ok, Msg, NChannel} ->
            do_publish(TopicId, MsgId, Msg, NChannel);
        {error, ReturnCode, NChannel} ->
            handle_out(puback, {TopicId, MsgId, ReturnCode}, NChannel)
    end;

handle_in(?SN_PUBACK_MSG(TopicId, MsgId, ReturnCode),
          Channel = #channel{
                       ctx = Ctx,
                       registry = Registry,
                       session = Session,
                       clientinfo = ClientInfo = #{clientid := ClientId}}) ->
    case ReturnCode of
        ?SN_RC_ACCEPTED ->
            case emqx_session:puback(MsgId, Session) of
                {ok, Msg, NSession} ->
                    ok = after_message_acked(ClientInfo, Msg, Channel),
                    {ok, Channel#channel{session = NSession}};
                {ok, Msg, Publishes, NSession} ->
                    ok = after_message_acked(ClientInfo, Msg, Channel),
                    handle_out(publish,
                               Publishes,
                               Channel#channel{session = NSession});
                {error, ?RC_PACKET_IDENTIFIER_IN_USE} ->
                    ?SLOG(warning, #{ msg => "commit_puback_failed"
                                    , msg_id => MsgId
                                    , reason => msg_id_inused
                                    }),
                    ok = metrics_inc(Ctx, 'packets.puback.inuse'),
                    {ok, Channel};
                {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
                    ?SLOG(warning, #{ msg => "commit_puback_failed"
                                    , msg_id => MsgId
                                    , reason => not_found
                                    }),
                    ok = metrics_inc(Ctx, 'packets.puback.missed'),
                    {ok, Channel}
            end;
        ?SN_RC_INVALID_TOPIC_ID ->
            case emqx_sn_registry:lookup_topic(Registry, ClientId, TopicId) of
                undefined ->
                    {ok, Channel};
                TopicName ->
                    %% notice that this TopicName maybe normal or predefined,
                    %% involving the predefined topic name in register to
                    %% enhance the gateway's robustness even inconsistent
                    %% with MQTT-SN channels
                    RegPkt = ?SN_REGISTER_MSG(TopicId, MsgId, TopicName),
                    {ok, {outgoing, RegPkt}, Channel}
            end;
        _ ->
            ?SLOG(error, #{ msg => "cannt_handle_PUBACK"
                          , return_code => ReturnCode
                          }),
            {ok, Channel}
    end;

handle_in(?SN_PUBREC_MSG(?SN_PUBREC, MsgId),
          Channel = #channel{ctx = Ctx,
                             session = Session,
                             clientinfo = ClientInfo}) ->
    case emqx_session:pubrec(MsgId, Session) of
        {ok, Msg, NSession} ->
            ok = after_message_acked(ClientInfo, Msg, Channel),
            NChannel = Channel#channel{session = NSession},
            handle_out(pubrel, MsgId, NChannel);
        {error, ?RC_PACKET_IDENTIFIER_IN_USE} ->
            ?SLOG(warning, #{ msg => "commit_PUBREC_failed"
                            , msg_id => MsgId
                            , reason => msg_id_inused
                            }),
            ok = metrics_inc(Ctx, 'packets.pubrec.inuse'),
            handle_out(pubrel, MsgId, Channel);
        {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
            ?SLOG(warning, #{ msg => "commit_PUBREC_failed"
                            , msg_id => MsgId
                            , reason => not_found
                            }),
            ok = metrics_inc(Ctx, 'packets.pubrec.missed'),
            handle_out(pubrel, MsgId, Channel)
    end;

handle_in(?SN_PUBREC_MSG(?SN_PUBREL, MsgId),
          Channel = #channel{ctx = Ctx, session = Session}) ->
    case emqx_session:pubrel(MsgId, Session) of
        {ok, NSession} ->
            NChannel = Channel#channel{session = NSession},
            handle_out(pubcomp, MsgId, NChannel);
        {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
            ?SLOG(warning, #{ msg => "commit_PUBREL_failed"
                            , msg_id => MsgId
                            , reason => not_found
                            }),
            ok = metrics_inc(Ctx, 'packets.pubrel.missed'),
            handle_out(pubcomp, MsgId, Channel)
    end;

handle_in(?SN_PUBREC_MSG(?SN_PUBCOMP, MsgId),
          Channel = #channel{ctx = Ctx, session = Session}) ->
    case emqx_session:pubcomp(MsgId, Session) of
        {ok, NSession} ->
            {ok, Channel#channel{session = NSession}};
        {ok, Publishes, NSession} ->
            handle_out(publish, Publishes,
                       Channel#channel{session = NSession});
        {error, ?RC_PACKET_IDENTIFIER_IN_USE} ->
            ?SLOG(warning, #{ msg => "commit_PUBCOMP_failed"
                            , msg_id => MsgId
                            , reason => msg_id_inused
                            }),
            ok = metrics_inc(Ctx, 'packets.pubcomp.inuse'),
            {ok, Channel};
        {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} ->
            ?SLOG(warning, #{ msg => "commit_PUBCOMP_failed"
                            , msg_id => MsgId
                            , reason => not_found
                            }),
            ok = metrics_inc(Ctx, 'packets.pubcomp.missed'),
            {ok, Channel}
    end;

handle_in(SubPkt = ?SN_SUBSCRIBE_MSG(_, MsgId, _), Channel) ->
    case emqx_misc:pipeline(
           [ fun preproc_subs_type/2
           , fun check_subscribe_authz/2
           , fun run_client_subs_hook/2
           , fun do_subscribe/2
           ], SubPkt, Channel) of
        {ok, {TopicId, _TopicName, SubOpts}, NChannel} ->
            GrantedQoS = maps:get(qos, SubOpts),
            SubAck = ?SN_SUBACK_MSG(#mqtt_sn_flags{qos = GrantedQoS},
                                    TopicId, MsgId, ?SN_RC_ACCEPTED),
            {ok, outgoing_and_update(SubAck), NChannel};
        {error, ReturnCode, NChannel} ->
            SubAck = ?SN_SUBACK_MSG(#mqtt_sn_flags{},
                                    ?SN_INVALID_TOPIC_ID,
                                    MsgId,
                                    ReturnCode),
            {ok, {outgoing, SubAck}, NChannel}
    end;

handle_in(UnsubPkt = ?SN_UNSUBSCRIBE_MSG(_, MsgId, TopicIdOrName),
          Channel) ->
    case emqx_misc:pipeline(
          [ fun preproc_unsub_type/2
          , fun run_client_unsub_hook/2
          , fun do_unsubscribe/2
          ], UnsubPkt, Channel) of
        {ok, _TopicName, NChannel} ->
            UnsubAck = ?SN_UNSUBACK_MSG(MsgId),
            {ok, outgoing_and_update(UnsubAck), NChannel};
        {error, Reason, NChannel} ->
            ?SLOG(warning, #{ msg => "unsubscribe_failed"
                            , topic => TopicIdOrName
                            , reason => Reason
                            }),
            %% XXX: Even if it fails, the reply is successful.
            UnsubAck = ?SN_UNSUBACK_MSG(MsgId),
            {ok, {outgoing, UnsubAck}, NChannel}
    end;

handle_in(?SN_PINGREQ_MSG(_ClientId),
          Channel = #channel{conn_state = asleep}) ->
    {ok, Outgoing, NChannel} = awake(Channel),
    NOutgoings = Outgoing ++ [{outgoing, ?SN_PINGRESP_MSG()}],
    {ok, NOutgoings, NChannel};

handle_in(?SN_PINGREQ_MSG(_ClientId), Channel) ->
    {ok, {outgoing, ?SN_PINGRESP_MSG()}, Channel};

handle_in(?SN_PINGRESP_MSG(), Channel) ->
    {ok, Channel};

handle_in(?SN_DISCONNECT_MSG(Duration), Channel) ->
    AckPkt = ?SN_DISCONNECT_MSG(undefined),
    case Duration of
        undefined ->
            shutdown(normal, AckPkt, Channel);
        _ ->
            %% TODO: asleep mechnisa
            {ok, {outgoing, AckPkt}, asleep(Duration, Channel)}
    end;

handle_in(?SN_WILLTOPICUPD_MSG(Flags, Topic),
          Channel = #channel{will_msg = WillMsg,
                             clientinfo = #{clientid := ClientId}}) ->
    NWillMsg = case Topic of
                   undefined -> undefined;
                   _ ->
                       update_will_topic(WillMsg, Flags, Topic, ClientId)
               end,
    AckPkt = ?SN_WILLTOPICRESP_MSG(?SN_RC_ACCEPTED),
    {ok, {outgoing, AckPkt}, Channel#channel{will_msg = NWillMsg}};

handle_in(?SN_WILLMSGUPD_MSG(Payload),
          Channel = #channel{will_msg = WillMsg}) ->
    AckPkt = ?SN_WILLMSGRESP_MSG(?SN_RC_ACCEPTED),
    NWillMsg = update_will_msg(WillMsg, Payload),
    {ok, {outgoing, AckPkt}, Channel#channel{will_msg = NWillMsg}};

handle_in({frame_error, Reason},
          Channel = #channel{conn_state = _ConnState}) ->
    ?SLOG(error, #{ msg => "unexpected_frame_error"
                  , reason => Reason
                  }),
    shutdown(Reason, Channel).

after_message_acked(ClientInfo, Msg, #channel{ctx = Ctx}) ->
    ok = metrics_inc(Ctx, 'messages.acked'),
    run_hooks_without_metrics(Ctx,
        'message.acked',
        [ClientInfo, emqx_message:set_header(puback_props, #{}, Msg)]).

outgoing_and_update(Pkt) ->
    [{outgoing, Pkt}, {event, update}].

%%--------------------------------------------------------------------
%% Handle Publish

check_qos3_enable(?SN_PUBLISH_MSG(Flags, TopicId, _MsgId, Data),
                  #channel{enable_qos3 = EnableQoS3}) ->
    #mqtt_sn_flags{qos = QoS} = Flags,
    case EnableQoS3 =:= false andalso QoS =:= ?QOS_NEG1 of
        true  ->
            ?SLOG(debug, #{ msg => "ignore_msg_due_to_qos3_disabled"
                          , topic_id => TopicId
                          , data => Data
                          }),
            {error, ?SN_RC_NOT_SUPPORTED};
        false ->
            ok
    end.

preproc_pub_pkt(?SN_PUBLISH_MSG(Flags, Topic0, _MsgId, Data),
                    Channel) ->
    #mqtt_sn_flags{topic_id_type = TopicIdType} = Flags,
    case TopicIdType of
        ?SN_NORMAL_TOPIC ->
            <<TopicId:16>> = Topic0,
            TopicIndicator = {id, TopicId},
            {ok, {TopicIndicator, Flags, Data}, Channel};
        ?SN_PREDEFINED_TOPIC ->
            TopicIndicator = {id, Topic0},
            {ok, {TopicIndicator, Flags, Data}, Channel};
        ?SN_SHORT_TOPIC ->
            case emqx_topic:wildcard(Topic0) of
                true ->
                    {error, ?SN_RC_NOT_SUPPORTED};
                false ->
                    TopicIndicator = {name, Topic0},
                    {ok, {TopicIndicator, Flags, Data}, Channel}
            end
    end.

convert_topic_id_to_name({{name, TopicName}, Flags, Data}, Channel) ->
    {ok, {TopicName, Flags, Data}, Channel};

convert_topic_id_to_name({{id, TopicId}, Flags, Data},
                         Channel = #channel{
                                      registry = Registry,
                                      clientinfo = #{clientid := ClientId}}
                        ) ->
    case emqx_sn_registry:lookup_topic(Registry, ClientId, TopicId) of
        undefined ->
            {error, ?SN_RC_INVALID_TOPIC_ID};
        TopicName ->
            {ok, {TopicName, Flags, Data}, Channel}
    end.

check_pub_authz({TopicName, _Flags, _Data},
              #channel{ctx = Ctx, clientinfo = ClientInfo}) ->
    case emqx_gateway_ctx:authorize(Ctx, ClientInfo, publish, TopicName) of
        allow -> ok;
        deny  -> {error, ?SN_RC_NOT_AUTHORIZE}
    end.

convert_pub_to_msg({TopicName, Flags, Data},
                   Channel = #channel{clientinfo = #{clientid := ClientId}}) ->
    #mqtt_sn_flags{qos = QoS, dup = Dup, retain = Retain} = Flags,
    NewQoS = get_corrected_qos(QoS),
    Message = put_message_headers(
                emqx_message:make(
                  ClientId, NewQoS, TopicName, Data,
                  #{dup => Dup, retain => Retain}, #{}), Channel),
    {ok, Message, Channel}.

put_message_headers(Msg, #channel{
                            conninfo = #{proto_ver := ProtoVer},
                            clientinfo = #{
                                protocol := Protocol,
                                username := Username,
                                peerhost := PeerHost}}) ->
    emqx_message:set_headers(
      #{proto_ver => ProtoVer,
        protocol => Protocol,
        username => Username,
        peerhost => PeerHost}, Msg).

get_corrected_qos(?QOS_NEG1) -> ?QOS_0;
get_corrected_qos(QoS) -> QoS.

do_publish(_TopicId, _MsgId, Msg = #message{qos = ?QOS_0}, Channel) ->
    _ = emqx_broker:publish(Msg),
    {ok, Channel};

do_publish(TopicId, MsgId, Msg = #message{qos = ?QOS_1}, Channel) ->
    _ = emqx_broker:publish(Msg),
    handle_out(puback, {TopicId, MsgId, ?SN_RC_ACCEPTED}, Channel);

do_publish(TopicId, MsgId, Msg = #message{qos = ?QOS_2},
           Channel = #channel{ctx = Ctx, session = Session}) ->
    case emqx_session:publish(MsgId, Msg, Session) of
        {ok, _PubRes, NSession} ->
            NChannel1 = ensure_timer(await_timer,
                                     Channel#channel{session = NSession}
                                    ),
            handle_out(pubrec, MsgId, NChannel1);
        {error, ?RC_PACKET_IDENTIFIER_IN_USE} ->
            ok = metrics_inc(Ctx, 'packets.publish.inuse'),
            %% XXX: Use PUBACK to reply a PUBLISH Error Code
            handle_out(puback , {TopicId, MsgId, ?SN_RC_NOT_SUPPORTED},
                       Channel);
        {error, ?RC_RECEIVE_MAXIMUM_EXCEEDED} ->
            ?SLOG(warning, #{ msg => "dropped_the_qos2_packet_due_to_awaiting_rel_full"
                            , msg_id => MsgId
                            }),
            ok = metrics_inc(Ctx, 'packets.publish.dropped'),
            handle_out(puback, {TopicId, MsgId, ?SN_RC_CONGESTION}, Channel)
    end.

%%--------------------------------------------------------------------
%% Handle Susbscribe

preproc_subs_type(?SN_SUBSCRIBE_MSG_TYPE(?SN_NORMAL_TOPIC,
                                         TopicName, QoS),
                  Channel = #channel{
                               registry = Registry,
                               clientinfo = #{clientid := ClientId}
                              }) ->
    %% If the gateway is able accept the subscription,
    %% it assigns a topic id to the received topic name
    %% and returns it within a SUBACK message
    case emqx_sn_registry:register_topic(Registry, ClientId, TopicName) of
        {error, too_large} ->
            {error, ?SN_EXCEED_LIMITATION};
        {error, wildcard_topic} ->
            %% If the client subscribes to a topic name which contains a
            %% wildcard character, the returning SUBACK message will contain
            %% the topic id value 0x0000. The GW will the use the registration
            %% procedure to inform the client about the to-be-used topic id
            %% value when it has the first PUBLISH message with a matching
            %% topic name to be sent to the client, see also Section 6.10.
            {ok, {?SN_INVALID_TOPIC_ID, TopicName, QoS}, Channel};
        TopicId when is_integer(TopicId) ->
            {ok, {TopicId, TopicName, QoS}, Channel}
    end;

preproc_subs_type(?SN_SUBSCRIBE_MSG_TYPE(?SN_PREDEFINED_TOPIC,
                                         TopicId, QoS),
                   Channel = #channel{
                                registry = Registry,
                                clientinfo = #{clientid := ClientId}
                               }) ->
    case emqx_sn_registry:lookup_topic(Registry,
                                       ClientId, TopicId) of
        undefined ->
            {error, ?SN_RC_INVALID_TOPIC_ID};
        TopicName ->
            {ok, {TopicId, TopicName, QoS}, Channel}
    end;

preproc_subs_type(?SN_SUBSCRIBE_MSG_TYPE(?SN_SHORT_TOPIC,
                                         TopicId, QoS),
                  Channel) ->
    TopicName = case is_binary(TopicId) of
                    true  -> TopicId;
                    false -> <<TopicId:16>>
                end,
    %% XXX: ?SN_INVALID_TOPIC_ID ???
    {ok, {?SN_INVALID_TOPIC_ID, TopicName, QoS}, Channel};

preproc_subs_type(?SN_SUBSCRIBE_MSG_TYPE(_Reserved, _TopicId, _QoS),
                  _Channel) ->
    {error, ?SN_RC_NOT_SUPPORTED}.

check_subscribe_authz({_TopicId, TopicName, _QoS},
                    Channel = #channel{ctx = Ctx, clientinfo = ClientInfo}) ->
    case emqx_gateway_ctx:authorize(Ctx, ClientInfo, subscribe, TopicName) of
        allow ->
            {ok, Channel};
        _ ->
            {error, ?SN_RC_NOT_AUTHORIZE}
    end.

run_client_subs_hook({TopicId, TopicName, QoS},
                     Channel = #channel{
                                  ctx = Ctx,
                                  clientinfo = ClientInfo}) ->
    {TopicName1, SubOpts0} = emqx_topic:parse(TopicName),
    TopicFilters = [{TopicName1, SubOpts0#{qos => QoS}}],
    case run_hooks(Ctx, 'client.subscribe',
                   [ClientInfo, #{}], TopicFilters) of
        [] ->
            ?SLOG(warning, #{ msg => "skip_to_subscribe"
                            , topic_name => TopicName
                            , reason => "'client.subscribe' filtered it"
                            }),
            {error, ?SN_EXCEED_LIMITATION};
        [{NTopicName, NSubOpts}|_] ->
            {ok, {TopicId, NTopicName, NSubOpts}, Channel}
    end.

do_subscribe({TopicId, TopicName, SubOpts},
             Channel = #channel{
                          session = Session,
                          clientinfo = ClientInfo
                                     = #{mountpoint := Mountpoint}}) ->
    NTopicName = emqx_mountpoint:mount(Mountpoint, TopicName),
    NSubOpts = maps:merge(?DEFAULT_SUBOPTS, SubOpts),
    case emqx_session:subscribe(ClientInfo, NTopicName, NSubOpts, Session) of
        {ok, NSession} ->
            {ok, {TopicId, NTopicName, NSubOpts},
             Channel#channel{session = NSession}};
        {error, ?RC_QUOTA_EXCEEDED} ->
            ?SLOG(warning, #{ msg => "cannt_subscribe_due_to_quota_exceeded"
                            , topic_name => TopicName
                            , reason => emqx_reason_codes:text(?RC_QUOTA_EXCEEDED)
                            }),
            {error, ?SN_EXCEED_LIMITATION}
    end.

%%--------------------------------------------------------------------
%% Handle Unsubscribe

preproc_unsub_type(?SN_UNSUBSCRIBE_MSG_TYPE(?SN_NORMAL_TOPIC,
                                            TopicName),
                   Channel) ->
    {ok, TopicName, Channel};
preproc_unsub_type(?SN_UNSUBSCRIBE_MSG_TYPE(?SN_PREDEFINED_TOPIC,
                                            TopicId),
                   Channel = #channel{
                                registry = Registry,
                                clientinfo = #{clientid := ClientId}
                               }) ->
    case emqx_sn_registry:lookup_topic(Registry, ClientId,
                                       TopicId) of
        undefined ->
            {error, not_found};
        TopicName ->
            {ok, TopicName, Channel}
    end;
preproc_unsub_type(?SN_UNSUBSCRIBE_MSG_TYPE(?SN_SHORT_TOPIC,
                                            TopicId),
                   Channel) ->
    TopicName = case is_binary(TopicId) of
                    true  -> TopicId;
                    false -> <<TopicId:16>>
                end,
    {ok, TopicName, Channel}.

run_client_unsub_hook(TopicName,
                      Channel = #channel{
                                   ctx = Ctx,
                                   clientinfo = ClientInfo
                                  }) ->
    TopicFilters = [emqx_topic:parse(TopicName)],
    case run_hooks(Ctx, 'client.unsubscribe',
                   [ClientInfo, #{}], TopicFilters) of
        [] ->
            {ok, [], Channel};
        NTopicFilters ->
            {ok, NTopicFilters, Channel}
    end.

do_unsubscribe(TopicFilters,
               Channel = #channel{
                            session = Session,
                            clientinfo = ClientInfo
                                       = #{mountpoint := Mountpoint}}) ->
    NChannel =
        lists:foldl(fun({TopicName, SubOpts}, ChannAcc) ->
            NTopicName = emqx_mountpoint:mount(Mountpoint, TopicName),
            NSubOpts = maps:merge(
                         emqx_gateway_utils:default_subopts(),
                         SubOpts
                        ),
            case emqx_session:unsubscribe(ClientInfo, NTopicName,
                                          NSubOpts, Session) of
                {ok, NSession} ->
                    ChannAcc#channel{session = NSession};
                {error, ?RC_NO_SUBSCRIPTION_EXISTED} ->
                    ChannAcc
            end
        end, Channel, TopicFilters),
    {ok, TopicFilters, NChannel}.

%%--------------------------------------------------------------------
%% Awake & Asleep

awake(Channel = #channel{session = Session}) ->
    {ok, Publishes, Session1} = emqx_session:replay(Session),
    {NPublishes, NSession} = case emqx_session:deliver([], Session1) of
        {ok, Session2} ->
            {Publishes, Session2};
        {ok, More, Session2} ->
            {lists:append(Publishes, More), Session2}
    end,
    {Packets, NChannel} = do_deliver(NPublishes,
                                     Channel#channel{session = NSession}),
    Outgoing = [{outgoing, Packets} || length(Packets) > 0],
    {ok, Outgoing, NChannel}.

asleep(Duration, Channel = #channel{conn_state = asleep}) ->
    %% 6.14: The client can also modify its sleep duration
    %% by sending a DISCONNECT message with a new value of
    %% the sleep duration
    ensure_timer(asleep_timer, Duration,
                 cancel_timer(asleep_timer, Channel)
                );

asleep(Duration, Channel = #channel{conn_state = connected}) ->
    ensure_timer(asleep_timer, Duration,
                 Channel#channel{conn_state = asleep}
                ).

%%--------------------------------------------------------------------
%% Handle outgoing packet
%%--------------------------------------------------------------------

-spec handle_out(atom(), term(), channel())
      -> {ok, channel()}
       | {ok, replies(), channel()}
       | {shutdown, Reason :: term(), channel()}
       | {shutdown, Reason :: term(), replies(), channel()}.

handle_out(connack, ?SN_RC_ACCEPTED,
           Channel = #channel{ctx = Ctx, conninfo = ConnInfo}) ->
    _ = run_hooks(Ctx, 'client.connack',
                  [ConnInfo, returncode_name(?SN_RC_ACCEPTED)],
                  #{}
                 ),
    return_connack(?SN_CONNACK_MSG(?SN_RC_ACCEPTED),
                   ensure_keepalive(Channel));

handle_out(connack, ReasonCode,
           Channel = #channel{ctx = Ctx, conninfo = ConnInfo}) ->
    Reason = returncode_name(ReasonCode),
    _ = run_hooks(Ctx, 'client.connack', [ConnInfo, Reason], #{}),
    AckPacket = ?SN_CONNACK_MSG(ReasonCode),
    shutdown(Reason, AckPacket, Channel);

handle_out(publish, Publishes, Channel) ->
    {Packets, NChannel} = do_deliver(Publishes, Channel),
    {ok, {outgoing, Packets}, NChannel};

handle_out(puback, {TopicId, MsgId, Rc}, Channel) ->
    {ok, {outgoing, ?SN_PUBACK_MSG(TopicId, MsgId, Rc)}, Channel};

handle_out(pubrec, MsgId, Channel) ->
    {ok, {outgoing, ?SN_PUBREC_MSG(?SN_PUBREC, MsgId)}, Channel};

handle_out(pubrel, MsgId, Channel) ->
    {ok, {outgoing, ?SN_PUBREC_MSG(?SN_PUBREL, MsgId)}, Channel};

handle_out(pubcomp, MsgId, Channel) ->
    {ok, {outgoing, ?SN_PUBREC_MSG(?SN_PUBCOMP, MsgId)}, Channel};

handle_out(disconnect, RC, Channel) ->
    DisPkt = ?SN_DISCONNECT_MSG(undefined),
    {ok, [{outgoing, DisPkt}, {close, RC}], Channel}.

%%--------------------------------------------------------------------
%% Return ConnAck
%%--------------------------------------------------------------------

return_connack(AckPacket, Channel) ->
    Replies = [{event, connected}, {outgoing, AckPacket}],
    case maybe_resume_session(Channel) of
        ignore -> {ok, Replies, Channel};
        {ok, Publishes, NSession} ->
            NChannel = Channel#channel{session  = NSession,
                                       resuming = false,
                                       pendings = []
                                      },
            {Packets, NChannel1} = do_deliver(Publishes, NChannel),
            Outgoing = [{outgoing, Packets} || length(Packets) > 0],
            {ok, Replies ++ Outgoing, NChannel1}
    end.

%%--------------------------------------------------------------------
%% Maybe Resume Session

maybe_resume_session(#channel{resuming = false}) ->
    ignore;
maybe_resume_session(#channel{session  = Session,
                              resuming = true,
                              pendings = Pendings}) ->
    {ok, Publishes, Session1} = emqx_session:replay(Session),
    case emqx_session:deliver(Pendings, Session1) of
        {ok, Session2} ->
            {ok, Publishes, Session2};
        {ok, More, Session2} ->
            {ok, lists:append(Publishes, More), Session2}
    end.

%%--------------------------------------------------------------------
%% Deliver publish: broker -> client
%%--------------------------------------------------------------------

%% return list(emqx_types:packet())
do_deliver({pubrel, MsgId}, Channel) ->
    {[?SN_PUBREC_MSG(?SN_PUBREL, MsgId)], Channel};

do_deliver({MsgId, Msg},
           Channel = #channel{
                        ctx = Ctx,
                        clientinfo = ClientInfo
                                   = #{mountpoint := Mountpoint}}) ->
    metrics_inc(Ctx, 'messages.delivered'),
    Msg1 = run_hooks_without_metrics(
             Ctx,
             'message.delivered',
             [ClientInfo],
             emqx_message:update_expiry(Msg)
            ),
    Msg2 = emqx_mountpoint:unmount(Mountpoint, Msg1),
    Packet = message_to_packet(MsgId, Msg2, Channel),
    {[Packet], Channel};

do_deliver([Publish], Channel) ->
    do_deliver(Publish, Channel);

do_deliver(Publishes, Channel) when is_list(Publishes) ->
    {Packets, NChannel} =
        lists:foldl(fun(Publish, {Acc, Chann}) ->
            {Packets, NChann} = do_deliver(Publish, Chann),
            {Packets ++ Acc, NChann}
        end, {[], Channel}, Publishes),
    {lists:reverse(Packets), NChannel}.

message_to_packet(MsgId, Message,
                  #channel{registry = Registry,
                           clientinfo = #{clientid := ClientId}}) ->
    QoS   = emqx_message:qos(Message),
    Topic = emqx_message:topic(Message),
    Payload = emqx_message:payload(Message),
    NMsgId = case QoS of
                   ?QOS_0 -> 0;
                   _ -> MsgId
               end,
    {TopicIdType, NTopicId} =
        case emqx_sn_registry:lookup_topic_id(Registry, ClientId, Topic) of
            {predef, PredefTopicId} ->
                {?SN_PREDEFINED_TOPIC, PredefTopicId};
            TopicId when is_integer(TopicId) ->
                {?SN_NORMAL_TOPIC, TopicId};
            undefined ->
                {?SN_SHORT_TOPIC, Topic}
        end,
    Flags = #mqtt_sn_flags{qos = QoS, topic_id_type = TopicIdType},
    ?SN_PUBLISH_MSG(Flags, NTopicId, NMsgId, Payload).

%%--------------------------------------------------------------------
%% Handle call
%%--------------------------------------------------------------------

-spec handle_call(Req :: term(), From :: term(), channel())
    -> {reply, Reply :: term(), channel()}
     | {reply, Reply :: term(), replies(), channel()}
     | {shutdown, Reason :: term(), Reply :: term(), channel()}
     | {shutdown, Reason :: term(), Reply :: term(),
        emqx_types:packet(), channel()}.
handle_call({subscribe, Topic, SubOpts}, _From, Channel) ->
    %% XXX: Only support short_topic_name
    SubProps = maps:get(sub_props, SubOpts, #{}),
    case maps:get(subtype, SubProps, short_topic_name) of
        short_topic_name ->
            case byte_size(Topic) of
                2 ->
                    case do_subscribe({?SN_INVALID_TOPIC_ID,
                                       Topic, SubOpts}, Channel) of
                        {ok, {_, NTopicName, NSubOpts}, NChannel} ->
                            reply({ok, {NTopicName, NSubOpts}}, NChannel);
                        {error, ?SN_EXCEED_LIMITATION} ->
                            reply({error, exceed_limitation}, Channel)
                    end;
                _ ->
                    reply({error, bad_topic_name}, Channel)
            end;
        predefined_topic_id  ->
            reply({error, only_support_short_name_topic}, Channel);
        _ ->
            reply({error, only_support_short_name_topic}, Channel)
    end;

handle_call({unsubscribe, Topic}, _From, Channel) ->
    TopicFilters = [emqx_topic:parse(Topic)],
    {ok, _, NChannel} = do_unsubscribe(TopicFilters, Channel),
    reply(ok, NChannel);

handle_call(subscriptions, _From, Channel = #channel{session = Session}) ->
    reply({ok, maps:to_list(emqx_session:info(subscriptions, Session))}, Channel);

handle_call(kick, _From, Channel) ->
    NChannel = ensure_disconnected(kicked, Channel),
    shutdown_and_reply(kicked, ok, NChannel);

handle_call(discard, _From, Channel) ->
    shutdown_and_reply(discarded, ok, Channel);

%% XXX: No Session Takeover
%handle_call({takeover, 'begin'}, _From, Channel = #channel{session = Session}) ->
%    reply(Session, Channel#channel{takeover = true});
%
%handle_call({takeover, 'end'}, _From, Channel = #channel{session  = Session,
%                                                  pendings = Pendings}) ->
%    ok = emqx_session:takeover(Session),
%    %% TODO: Should not drain deliver here (side effect)
%    Delivers = emqx_misc:drain_deliver(),
%    AllPendings = lists:append(Delivers, Pendings),
%    shutdown_and_reply(takenover, AllPendings, Channel);

%handle_call(list_authz_cache, _From, Channel) ->
%    {reply, emqx_authz_cache:list_authz_cache(), Channel};

%% XXX: No Quota Now
% handle_call({quota, Policy}, _From, Channel) ->
%     Zone = info(zone, Channel),
%     Quota = emqx_limiter:init(Zone, Policy),
%     reply(ok, Channel#channel{quota = Quota});

handle_call(Req, _From, Channel) ->
    ?SLOG(error, #{ msg => "unexpected_call"
                  , call => Req
                  }),
    reply(ignored, Channel).

%%--------------------------------------------------------------------
%% Handle Cast
%%--------------------------------------------------------------------

-spec handle_cast(Req :: term(), channel())
      -> ok | {ok, channel()} | {shutdown, Reason :: term(), channel()}.
handle_cast(_Req, Channel) ->
    {ok, Channel}.

%%--------------------------------------------------------------------
%% Handle Info
%%--------------------------------------------------------------------

-spec handle_info(Info :: term(), channel())
      -> ok | {ok, channel()} | {shutdown, Reason :: term(), channel()}.

handle_info({sock_closed, Reason},
            Channel = #channel{conn_state = idle}) ->
    shutdown(Reason, Channel);

handle_info({sock_closed, Reason},
            Channel = #channel{conn_state = connecting}) ->
    shutdown(Reason, Channel);

handle_info({sock_closed, Reason},
            Channel = #channel{conn_state = connected,
                               clientinfo = _ClientInfo}) ->
    %% XXX: Flapping detect ???
    %% How to get the flapping detect policy ???
    %emqx_zone:enable_flapping_detect(Zone)
    %    andalso emqx_flapping:detect(ClientInfo),
    NChannel = ensure_disconnected(Reason, mabye_publish_will_msg(Channel)),
    %% XXX: Session keepper detect here
    shutdown(Reason, NChannel);

handle_info({sock_closed, Reason},
            Channel = #channel{conn_state = disconnected}) ->
    ?SLOG(error, #{ msg => "unexpected_sock_closed"
                  , reason => Reason
                  }),
    {ok, Channel};

handle_info(clean_authz_cache, Channel) ->
    ok = emqx_authz_cache:empty_authz_cache(),
    {ok, Channel};

handle_info(Info, Channel) ->
    ?SLOG(error, #{ msg => "unexpected_info"
                  , info => Info
                  }),
    {ok, Channel}.

%%--------------------------------------------------------------------
%% Ensure disconnected

ensure_disconnected(Reason, Channel = #channel{
                                         ctx = Ctx,
                                         conninfo = ConnInfo,
                                         clientinfo = ClientInfo}) ->
    NConnInfo = ConnInfo#{disconnected_at => erlang:system_time(millisecond)},
    ok = run_hooks(Ctx, 'client.disconnected',
                   [ClientInfo, Reason, NConnInfo]),
    Channel#channel{conninfo = NConnInfo, conn_state = disconnected}.

mabye_publish_will_msg(Channel = #channel{will_msg = undefined}) ->
    Channel;
mabye_publish_will_msg(Channel = #channel{will_msg = WillMsg}) ->
    ok = publish_will_msg(put_message_headers(WillMsg, Channel)),
    Channel#channel{will_msg = undefined}.

publish_will_msg(Msg) ->
    _ = emqx_broker:publish(Msg),
    ok.

%%--------------------------------------------------------------------
%% Handle Delivers from broker to client
%%--------------------------------------------------------------------

-spec handle_deliver(list(emqx_types:deliver()), channel())
      -> {ok, channel()}
       | {ok, replies(), channel()}.
handle_deliver(Delivers, Channel = #channel{
                                      ctx = Ctx,
                                      conn_state = ConnState,
                                      session    = Session,
                                      clientinfo = #{clientid := ClientId}})
  when ConnState =:= disconnected;
       ConnState =:= asleep ->
    NSession = emqx_session:enqueue(
                 ignore_local(maybe_nack(Delivers), ClientId, Session, Ctx),
                 Session
                ),
    {ok, Channel#channel{session = NSession}};

handle_deliver(Delivers, Channel = #channel{
                                      ctx = Ctx,
                                      takeover = true,
                                      pendings = Pendings,
                                      session = Session,
                                      clientinfo = #{clientid := ClientId}}) ->
    NPendings = lists:append(
                  Pendings,
                  ignore_local(maybe_nack(Delivers), ClientId, Session, Ctx)
                 ),
    {ok, Channel#channel{pendings = NPendings}};

handle_deliver(Delivers, Channel = #channel{
                                      ctx = Ctx,
                                      session = Session,
                                      clientinfo = #{clientid := ClientId}}) ->
    case emqx_session:deliver(
           ignore_local(Delivers, ClientId, Session, Ctx),
           Session
          ) of
        {ok, Publishes, NSession} ->
            NChannel = Channel#channel{session = NSession},
            handle_out(publish, Publishes,
                       ensure_timer(retry_timer, NChannel));
        {ok, NSession} ->
            {ok, Channel#channel{session = NSession}}
    end.

ignore_local(Delivers, Subscriber, Session, Ctx) ->
    Subs = emqx_session:info(subscriptions, Session),
    lists:dropwhile(fun({deliver, Topic, #message{from = Publisher}}) ->
                        case maps:find(Topic, Subs) of
                            {ok, #{nl := 1}} when Subscriber =:= Publisher ->
                                ok = metrics_inc(Ctx, 'delivery.dropped'),
                                ok = metrics_inc(Ctx, 'delivery.dropped.no_local'),
                                true;
                            _ ->
                                false
                        end
                    end, Delivers).

%% Nack delivers from shared subscription
maybe_nack(Delivers) ->
    lists:filter(fun not_nacked/1, Delivers).

not_nacked({deliver, _Topic, Msg}) ->
    not (emqx_shared_sub:is_ack_required(Msg)
         andalso (ok == emqx_shared_sub:nack_no_connection(Msg))).

%%--------------------------------------------------------------------
%% Handle timeout
%%--------------------------------------------------------------------

-spec handle_timeout(reference(), Msg :: term(), channel())
      -> {ok, channel()}
       | {ok, replies(), channel()}
       | {shutdown, Reason :: term(), channel()}.

handle_timeout(_TRef, {keepalive, _StatVal},
               Channel = #channel{keepalive = undefined}) ->
    {ok, Channel};
handle_timeout(_TRef, {keepalive, _StatVal},
               Channel = #channel{conn_state = ConnState})
  when ConnState =:= disconnected;
       ConnState =:= asleep ->
    {ok, Channel};
handle_timeout(_TRef, {keepalive, StatVal},
               Channel = #channel{keepalive = Keepalive}) ->
    case emqx_keepalive:check(StatVal, Keepalive) of
        {ok, NKeepalive} ->
            NChannel = Channel#channel{keepalive = NKeepalive},
            {ok, reset_timer(alive_timer, NChannel)};
        {error, timeout} ->
            handle_out(disconnect, ?RC_KEEP_ALIVE_TIMEOUT, Channel)
    end;

handle_timeout(_TRef, retry_delivery,
               Channel = #channel{conn_state = disconnected}) ->
    {ok, Channel};
handle_timeout(_TRef, retry_delivery,
               Channel = #channel{conn_state = asleep}) ->
    {ok, reset_timer(retry_timer, Channel)};
handle_timeout(_TRef, retry_delivery,
               Channel = #channel{session = Session}) ->
    case emqx_session:retry(Session) of
        {ok, NSession} ->
            {ok, clean_timer(retry_timer, Channel#channel{session = NSession})};
        {ok, Publishes, Timeout, NSession} ->
            NChannel = Channel#channel{session = NSession},
            handle_out(publish, Publishes, reset_timer(retry_timer, Timeout, NChannel))
    end;

handle_timeout(_TRef, expire_awaiting_rel,
               Channel = #channel{conn_state = disconnected}) ->
    {ok, Channel};
handle_timeout(_TRef, expire_awaiting_rel,
               Channel = #channel{conn_state = asleep}) ->
    {ok, reset_timer(await_timer, Channel)};
handle_timeout(_TRef, expire_awaiting_rel,
               Channel = #channel{session = Session}) ->
    case emqx_session:expire(awaiting_rel, Session) of
        {ok, NSession} ->
            {ok, clean_timer(await_timer, Channel#channel{session = NSession})};
        {ok, Timeout, NSession} ->
            {ok, reset_timer(await_timer, Timeout, Channel#channel{session = NSession})}
    end;

handle_timeout(_TRef, expire_asleep, Channel) ->
    shutdown(asleep_timeout, Channel);

handle_timeout(_TRef, Msg, Channel) ->
    ?SLOG(error, #{ msg => "unexpected_timeout"
                  , timeout_msg => Msg
                  }),
    {ok, Channel}.

%%--------------------------------------------------------------------
%% Terminate
%%--------------------------------------------------------------------

terminate(_Reason, _Channel) ->
    ok.

reply(Reply, Channel) ->
    {reply, Reply, Channel}.

shutdown(Reason, Channel) ->
    {shutdown, Reason, Channel}.

shutdown(Reason, AckFrame, Channel) ->
    {shutdown, Reason, AckFrame, Channel}.

shutdown_and_reply(Reason, Reply, Channel) ->
    {shutdown, Reason, Reply, Channel}.

%%--------------------------------------------------------------------
%% Will

update_will_topic(undefined, #mqtt_sn_flags{qos = QoS, retain = Retain},
                  Topic, ClientId) ->
    WillMsg0 = emqx_message:make(ClientId, QoS, Topic, <<>>),
    emqx_message:set_flag(retain, Retain, WillMsg0);
update_will_topic(Will, #mqtt_sn_flags{qos = QoS, retain = Retain},
                  Topic, _ClientId) ->
    emqx_message:set_flag(retain, Retain,
                          Will#message{qos = QoS, topic = Topic}).

update_will_msg(Will, Payload) ->
    Will#message{payload = Payload}.

%%--------------------------------------------------------------------
%% Timer

cancel_timer(Name, Channel = #channel{timers = Timers}) ->
    case maps:get(Name, Timers, undefined) of
        undefined ->
            Channel;
        TRef ->
            emqx_misc:cancel_timer(TRef),
            Channel#channel{timers = maps:without([Name], Timers)}
    end.

ensure_timer(Name, Channel = #channel{timers = Timers}) ->
    TRef = maps:get(Name, Timers, undefined),
    Time = interval(Name, Channel),
    case TRef == undefined andalso is_integer(Time) andalso Time > 0 of
        true  -> ensure_timer(Name, Time, Channel);
        false -> Channel %% Timer disabled or exists
    end.

ensure_timer(Name, Time, Channel = #channel{timers = Timers}) ->
    Msg = maps:get(Name, ?TIMER_TABLE),
    TRef = emqx_misc:start_timer(Time, Msg),
    Channel#channel{timers = Timers#{Name => TRef}}.

reset_timer(Name, Channel) ->
    ensure_timer(Name, clean_timer(Name, Channel)).

reset_timer(Name, Time, Channel) ->
    ensure_timer(Name, Time, clean_timer(Name, Channel)).

clean_timer(Name, Channel = #channel{timers = Timers}) ->
    Channel#channel{timers = maps:remove(Name, Timers)}.

interval(alive_timer, #channel{keepalive = KeepAlive}) ->
    emqx_keepalive:info(interval, KeepAlive);
interval(retry_timer, #channel{session = Session}) ->
    emqx_session:info(retry_interval, Session);
interval(await_timer, #channel{session = Session}) ->
    emqx_session:info(await_rel_timeout, Session).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

run_hooks(Ctx, Name, Args) ->
    emqx_gateway_ctx:metrics_inc(Ctx, Name),
    emqx_hooks:run(Name, Args).

run_hooks(Ctx, Name, Args, Acc) ->
    emqx_gateway_ctx:metrics_inc(Ctx, Name),
    emqx_hooks:run_fold(Name, Args, Acc).

run_hooks_without_metrics(_Ctx, Name, Args) ->
    emqx_hooks:run(Name, Args).

run_hooks_without_metrics(_Ctx, Name, Args, Acc) ->
    emqx_hooks:run_fold(Name, Args, Acc).

metrics_inc(Ctx, Name) ->
    emqx_gateway_ctx:metrics_inc(Ctx, Name).

returncode_name(?SN_RC_ACCEPTED) -> accepted;
returncode_name(?SN_RC_CONGESTION) -> rejected_congestion;
returncode_name(?SN_RC_INVALID_TOPIC_ID) -> rejected_invaild_topic_id;
returncode_name(?SN_RC_NOT_SUPPORTED) -> rejected_not_supported;
returncode_name(?SN_RC_NOT_AUTHORIZE) -> rejected_not_authorize;
returncode_name(?SN_RC_FAILED_SESSION) -> rejected_failed_open_session;
returncode_name(?SN_EXCEED_LIMITATION) -> rejected_exceed_limitation;
returncode_name(_) -> accepted.
