-module('rebar.config').

-export([do/2]).

do(Dir, CONFIG) ->
    case iolist_to_binary(Dir) of
        <<".">> ->
            C1 = deps(CONFIG),
            Config = dialyzer(C1),
            maybe_dump(Config ++ [{overrides, overrides()}] ++ coveralls() ++ config());
        _ ->
            CONFIG
    end.

bcrypt() ->
    {bcrypt, {git, "https://github.com/emqx/erlang-bcrypt.git", {branch, "0.6.0"}}}.

quicer() ->
    {quicer, {git, "https://github.com/emqx/quic.git", {tag, "0.0.9"}}}.

deps(Config) ->
    {deps, OldDeps} = lists:keyfind(deps, 1, Config),
    MoreDeps = [bcrypt() || provide_bcrypt_dep()] ++
        [quicer() || is_quicer_supported()],
    lists:keystore(deps, 1, Config, {deps, OldDeps ++ MoreDeps}).

overrides() ->
    [ {add, [ {extra_src_dirs, [{"etc", [{recursive,true}]}]}
            , {erl_opts, [{compile_info, [{emqx_vsn, get_vsn()}]}]}
            ]}
    ] ++ snabbkaffe_overrides().

%% Temporary workaround for a rebar3 erl_opts duplication
%% bug. Ideally, we want to set this define globally
snabbkaffe_overrides() ->
    Apps = [snabbkaffe, ekka, mria],
    [{add, App, [{erl_opts, [{d, snk_kind, msg}]}]} || App <- Apps].

config() ->
    [ {cover_enabled, is_cover_enabled()}
    , {profiles, profiles()}
    , {plugins, plugins()}
    ].

is_cover_enabled() ->
    case os:getenv("ENABLE_COVER_COMPILE") of
        "1"-> true;
        "true" -> true;
        _ -> false
    end.

is_enterprise(ce) -> false;
is_enterprise(ee) -> true.

is_quicer_supported() ->
    not (false =/= os:getenv("BUILD_WITHOUT_QUIC") orelse
         is_win32() orelse is_centos_6()
        ).

is_centos_6() ->
    %% reason:
    %% glibc is too old
    case file:read_file("/etc/centos-release") of
        {ok, <<"CentOS release 6", _/binary >>} ->
            true;
        _ ->
            false
    end.

is_win32() ->
    win32 =:= element(1, os:type()).

project_app_dirs(Edition) ->
    ["apps/*"] ++
    case is_enterprise(Edition) of
        true -> ["lib-ee/*"];
        false -> []
    end.

plugins() ->
    [ {relup_helper,{git,"https://github.com/emqx/relup_helper", {tag, "2.0.0"}}}
    , {er_coap_client, {git, "https://github.com/emqx/er_coap_client", {tag, "v1.0.4"}}}
      %% emqx main project does not require port-compiler
      %% pin at root level for deterministic
    , {pc, {git, "https://github.com/emqx/port_compiler.git", {tag, "v1.11.1"}}}
    ]
    %% test plugins are concatenated to default profile plugins
    %% otherwise rebar3 test profile runs are super slow
    ++ test_plugins().

test_plugins() ->
    [ {rebar3_proper, "0.12.1"}
    , {coveralls, {git, "https://github.com/emqx/coveralls-erl", {tag, "v2.2.0-emqx-1"}}}
    ].

test_deps() ->
    [ {bbmustache, "1.10.0"}
    , {meck, "0.9.2"}
    , {proper, "1.4.0"}
    ].

common_compile_opts() ->
    [ debug_info % alwyas include debug_info
    , {compile_info, [{emqx_vsn, get_vsn()}]}
    ] ++
    [{d, 'EMQX_BENCHMARK'} || os:getenv("EMQX_BENCHMARK") =:= "1" ].

prod_compile_opts() ->
    [ compressed
    , deterministic
    , warnings_as_errors
    | common_compile_opts()
    ].

prod_overrides() ->
    [{add, [ {erl_opts, [deterministic]}]}].

profiles() ->
    Vsn = get_vsn(),
    [ {'emqx',
       [ {erl_opts, prod_compile_opts()}
       , {relx, relx(Vsn, cloud, bin, ce)}
       , {overrides, prod_overrides()}
       , {project_app_dirs, project_app_dirs(ce)}
       , {post_hooks, [{compile, "./build emqx doc"}]}
       ]}
    , {'emqx-pkg',
       [ {erl_opts, prod_compile_opts()}
       , {relx, relx(Vsn, cloud, pkg, ce)}
       , {overrides, prod_overrides()}
       , {project_app_dirs, project_app_dirs(ce)}
       , {post_hooks, [{compile, "./build emqx-pkg doc"}]}
       ]}
    , {'emqx-enterprise',
       [ {erl_opts, prod_compile_opts()}
       , {relx, relx(Vsn, cloud, bin, ee)}
       , {overrides, prod_overrides()}
       , {project_app_dirs, project_app_dirs(ee)}
       , {post_hooks, [{compile, "./build emqx-enterprise doc"}]}
       ]}
    , {'emqx-enterprise-pkg',
       [ {erl_opts, prod_compile_opts()}
       , {relx, relx(Vsn, cloud, pkg, ee)}
       , {overrides, prod_overrides()}
       , {project_app_dirs, project_app_dirs(ee)}
       , {post_hooks, [{compile, "./build emqx-enterprise-pkg doc"}]}
       ]}
    , {'emqx-edge',
       [ {erl_opts, prod_compile_opts()}
       , {relx, relx(Vsn, edge, bin, ce)}
       , {overrides, prod_overrides()}
       , {project_app_dirs, project_app_dirs(ce)}
       , {post_hooks, [{compile, "./build emqx-edge doc"}]}
       ]}
    , {'emqx-edge-pkg',
       [ {erl_opts, prod_compile_opts()}
       , {relx, relx(Vsn, edge, pkg, ce)}
       , {overrides, prod_overrides()}
       , {project_app_dirs, project_app_dirs(ce)}
       , {post_hooks, [{compile, "./build emqx-edge-pkg doc"}]}
       ]}
    , {check,
       [ {erl_opts, common_compile_opts()}
       , {project_app_dirs, project_app_dirs(ce)}
       ]}
    , {test,
       [ {deps, test_deps()}
       , {erl_opts, common_compile_opts() ++ erl_opts_i(ce) }
       , {extra_src_dirs, [{"test", [{recursive, true}]}]}
       , {project_app_dirs, project_app_dirs(ce)}
       ]}
    ].

%% RelType: cloud (full size) | edge (slim size)
%% PkgType: bin | pkg
relx(Vsn, RelType, PkgType, Edition) ->
    [ {include_src,false}
    , {include_erts, true}
    , {extended_start_script,false}
    , {generate_start_script,false}
    , {sys_config,false}
    , {vm_args,false}
    , {release, {emqx, Vsn}, relx_apps(RelType, Edition)}
    , {overlay, relx_overlay(RelType, Edition)}
    , {overlay_vars, [ {built_on_arch, rebar_utils:get_arch()}
                     , {emqx_description, emqx_description(RelType, Edition)}
                     | overlay_vars(RelType, PkgType, Edition)]}
    ].

emqx_description(cloud, ee) -> "EMQ X Enterprise Edition";
emqx_description(cloud, ce) -> "EMQ X Community Edition";
emqx_description(edge, ce)  -> "EMQ X Edge Edition".

overlay_vars(RelType, PkgType, _Edition) ->
    overlay_vars_rel(RelType) ++ overlay_vars_pkg(PkgType).

%% vars per release type, cloud or edge
overlay_vars_rel(RelType) ->
    VmArgs = case RelType of
                 cloud -> "vm.args";
                 edge -> "vm.args.edge"
             end,

    [ {vm_args_file, VmArgs}
    ].

%% vars per packaging type, bin(zip/tar.gz/docker) or pkg(rpm/deb)
overlay_vars_pkg(bin) ->
    [ {platform_bin_dir, "bin"}
    , {platform_data_dir, "data"}
    , {platform_etc_dir, "etc"}
    , {platform_lib_dir, "lib"}
    , {platform_log_dir, "log"}
    , {platform_plugins_dir, "plugins"}
    , {runner_root_dir, "$(cd $(dirname $(readlink $0 || echo $0))/..; pwd -P)"}
    , {runner_bin_dir, "$RUNNER_ROOT_DIR/bin"}
    , {runner_etc_dir, "$RUNNER_ROOT_DIR/etc"}
    , {runner_lib_dir, "$RUNNER_ROOT_DIR/lib"}
    , {runner_log_dir, "$RUNNER_ROOT_DIR/log"}
    , {runner_data_dir, "$RUNNER_ROOT_DIR/data"}
    , {runner_user, ""}
    ];
overlay_vars_pkg(pkg) ->
    [ {platform_bin_dir, ""}
    , {platform_data_dir, "/var/lib/emqx"}
    , {platform_etc_dir, "/etc/emqx"}
    , {platform_lib_dir, ""}
    , {platform_log_dir, "/var/log/emqx"}
    , {platform_plugins_dir, "/var/lib/emqx/plugins"}
    , {runner_root_dir, "/usr/lib/emqx"}
    , {runner_bin_dir, "/usr/bin"}
    , {runner_etc_dir, "/etc/emqx"}
    , {runner_lib_dir, "$RUNNER_ROOT_DIR/lib"}
    , {runner_log_dir, "/var/log/emqx"}
    , {runner_data_dir, "/var/lib/emqx"}
    , {runner_user, "emqx"}
    ].

relx_apps(ReleaseType, Edition) ->
    [ kernel
    , sasl
    , crypto
    , public_key
    , asn1
    , syntax_tools
    , ssl
    , os_mon
    , inets
    , compiler
    , runtime_tools
    , {emqx, load} % started by emqx_machine
    , {emqx_conf, load}
    , emqx_machine
    , {mnesia, load}
    , {ekka, load}
    , {emqx_plugin_libs, load}
    , {esasl, load}
    , observer_cli
    , system_monitor
    , emqx_http_lib
    , emqx_resource
    , emqx_connector
    , emqx_authn
    , emqx_authz
    , emqx_auto_subscribe
    , emqx_gateway
    , emqx_exhook
    , emqx_bridge
    , emqx_rule_engine
    , emqx_modules
    , emqx_management
    , emqx_dashboard
    , emqx_retainer
    , emqx_statsd
    , emqx_prometheus
    , emqx_psk
    , emqx_slow_subs
    , emqx_plugins
    ]
    ++ [quicer || is_quicer_supported()]
    %++ [emqx_license || is_enterprise(Edition)]
    ++ [bcrypt || provide_bcrypt_release(ReleaseType)]
    ++ relx_apps_per_rel(ReleaseType)
       %% NOTE: applications below are only loaded after node start/restart
       %% TODO: Add loaded/unloaded state to plugin apps
       %%       then we can always start plugin apps
    ++ [{N, load} || N <- relx_plugin_apps(ReleaseType, Edition)].

relx_apps_per_rel(cloud) ->
    [ xmerl
    | [{observer, load} || is_app(observer)]
    ];
relx_apps_per_rel(edge) ->
    [].

is_app(Name) ->
    case application:load(Name) of
        ok -> true;
        {error,{already_loaded, _}} -> true;
        _ -> false
    end.

relx_plugin_apps(ReleaseType, Edition) ->
    relx_plugin_apps_per_rel(ReleaseType)
    ++ relx_plugin_apps_enterprise(Edition).

relx_plugin_apps_per_rel(cloud) ->
    [];
relx_plugin_apps_per_rel(edge) ->
    [].

relx_plugin_apps_enterprise(ee) ->
    [list_to_atom(A) || A <- filelib:wildcard("*", "lib-ee"),
                        filelib:is_dir(filename:join(["lib-ee", A]))];
relx_plugin_apps_enterprise(ce) -> [].

relx_overlay(ReleaseType, Edition) ->
    [ {mkdir, "log/"}
    , {mkdir, "data/"}
    , {mkdir, "plugins"}
    , {mkdir, "data/mnesia"}
    , {mkdir, "data/configs"}
    , {mkdir, "data/patches"}
    , {mkdir, "data/scripts"}
    , {template, "data/emqx_vars", "releases/emqx_vars"}
    , {template, "data/BUILT_ON", "releases/{{release_version}}/BUILT_ON"}
    , {copy, "bin/emqx", "bin/emqx"}
    , {copy, "bin/emqx_ctl", "bin/emqx_ctl"}
    , {copy, "bin/node_dump", "bin/node_dump"}
    , {copy, "bin/install_upgrade.escript", "bin/install_upgrade.escript"}
    , {copy, "bin/emqx", "bin/emqx-{{release_version}}"} %% for relup
    , {copy, "bin/emqx_ctl", "bin/emqx_ctl-{{release_version}}"} %% for relup
    , {copy, "bin/install_upgrade.escript", "bin/install_upgrade.escript-{{release_version}}"} %% for relup
    , {copy, "apps/emqx_gateway/src/lwm2m/lwm2m_xml", "etc/lwm2m_xml"}
    , {copy, "apps/emqx_authz/etc/acl.conf", "etc/acl.conf"}
    , {template, "bin/emqx.cmd", "bin/emqx.cmd"}
    , {template, "bin/emqx_ctl.cmd", "bin/emqx_ctl.cmd"}
    , {copy, "bin/nodetool", "bin/nodetool"}
    , {copy, "bin/nodetool", "bin/nodetool-{{release_version}}"}
    ] ++ etc_overlay(ReleaseType, Edition).

etc_overlay(ReleaseType, _Edition) ->
    Templates = emqx_etc_overlay(ReleaseType),
    [ {mkdir, "etc/"}
    , {copy, "{{base_dir}}/lib/emqx/etc/certs","etc/"}
    ] ++
    lists:map(
      fun({From, To}) -> {template, From, To};
         (FromTo)     -> {template, FromTo, FromTo}
      end, Templates)
    ++ extra_overlay(ReleaseType).

extra_overlay(cloud) ->
    [
    ];
extra_overlay(edge) ->
    [].
emqx_etc_overlay(cloud) ->
    emqx_etc_overlay_common() ++
    [ {"{{base_dir}}/lib/emqx/etc/emqx_cloud/vm.args","etc/vm.args"}
    ];
emqx_etc_overlay(edge) ->
    emqx_etc_overlay_common() ++
    [ {"{{base_dir}}/lib/emqx/etc/emqx_edge/vm.args","etc/vm.args"}
    ].

emqx_etc_overlay_common() ->
    [ {"{{base_dir}}/lib/emqx_conf/etc/emqx.conf.all", "etc/emqx.conf"}
    , {"{{base_dir}}/lib/emqx/etc/ssl_dist.conf", "etc/ssl_dist.conf"}
    ].

get_vsn() ->
    %% to make it compatible to Linux and Windows,
    %% we must use bash to execute the bash file
    %% because "./" will not be recognized as an internal or external command
    PkgVsn = os:cmd("bash pkg-vsn.sh"),
    re:replace(PkgVsn, "\n", "", [{return ,list}]).

maybe_dump(Config) ->
    is_debug() andalso file:write_file("rebar.config.rendered", [io_lib:format("~p.\n", [I]) || I <- Config]),
    Config.

is_debug() -> is_debug("DEBUG") orelse is_debug("DIAGNOSTIC").

is_debug(VarName) ->
    case os:getenv(VarName) of
        false -> false;
        "" -> false;
        _ -> true
    end.

provide_bcrypt_dep() ->
    not is_win32().

provide_bcrypt_release(ReleaseType) ->
    provide_bcrypt_dep() andalso ReleaseType =:= cloud.

erl_opts_i(Edition) ->
    [{i, "apps"}] ++
    [{i, Dir}  || Dir <- filelib:wildcard(filename:join(["apps", "*", "include"]))] ++
    case is_enterprise(Edition) of
        true ->
            [{i, Dir}  || Dir <- filelib:wildcard(filename:join(["lib-ee", "*", "include"]))];
        false -> []
    end.

dialyzer(Config) ->
    {dialyzer, OldDialyzerConfig} = lists:keyfind(dialyzer, 1, Config),

    AppsToAnalyse = case os:getenv("DIALYZER_ANALYSE_APP") of
        false ->
            [];
        Value ->
            [ list_to_atom(App) || App <- string:tokens(Value, ",")]
    end,

    AppNames = app_names(),

    KnownApps = [Name ||  Name <- AppsToAnalyse, lists:member(Name, AppNames)],

    AppsToExclude = AppNames -- KnownApps,

    case length(AppsToAnalyse) > 0 of
        true ->
            lists:keystore(dialyzer, 1, Config, {dialyzer, OldDialyzerConfig ++ [{exclude_apps, AppsToExclude}]});
        false ->
            Config
    end.

coveralls() ->
    case {os:getenv("GITHUB_ACTIONS"), os:getenv("GITHUB_TOKEN")} of
      {"true", Token} when is_list(Token) ->
        Cfgs = [{coveralls_repo_token, Token},
                {coveralls_service_job_id, os:getenv("GITHUB_RUN_ID")},
                {coveralls_commit_sha, os:getenv("GITHUB_SHA")},
                {coveralls_coverdata, "_build/test/cover/*.coverdata"},
                {coveralls_service_name, "github"}],
        case os:getenv("GITHUB_EVENT_NAME") =:= "pull_request"
            andalso string:tokens(os:getenv("GITHUB_REF"), "/") of
            [_, "pull", PRNO, _] ->
                [{coveralls_service_pull_request, PRNO} | Cfgs];
            _ ->
                Cfgs
        end;
      _ ->
        []
    end.

app_names() -> list_dir("apps") ++ list_dir("lib-ee").

list_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Names} = file:list_dir(Dir),
            [list_to_atom(Name) || Name <- Names, filelib:is_dir(filename:join([Dir, Name]))];
        false ->
            []
    end.
