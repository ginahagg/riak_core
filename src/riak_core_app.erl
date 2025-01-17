%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(riak_core_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-include_lib("kernel/include/logger.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    %% Don't add our system_monitor event handler here.  Instead, let
    %% riak_core_sysmon_minder start it, because that process can act
    %% on any handler crash notification, whereas we cannot.

    case application:get_env(riak_core, delayed_start) of
        {ok, Delay} ->
            ?LOG_INFO("Delaying riak_core startup as requested"),
            timer:sleep(Delay);
        _ ->
            ok
    end,

    %% Validate that the ring state directory exists
    riak_core_util:start_app_deps(riak_core),
    RingStateDir = app_helper:get_env(riak_core, ring_state_dir),
    case filelib:ensure_dir(filename:join(RingStateDir, "dummy")) of
        ok ->
            ok;
        {error, RingReason} ->
            ?LOG_CRITICAL(
              "Ring state directory ~p does not exist, "
              "and could not be created: ~p",
              [RingStateDir, ?LOG_ERROR(RingReason)]),
            throw({error, invalid_ring_state_dir})
    end,

    %% Register our cluster_info app callback modules, with catch if
    %% the app is missing or packaging is broken.
    catch cluster_info:register_app(riak_core_cinfo_core),

    %% add these defaults now to supplement the set that may have been
    %% configured in app.config
    riak_core_bucket:append_bucket_defaults(riak_core_bucket_type:defaults(default_type)),

    %% Spin up the supervisor; prune ring files as necessary
    case riak_core_sup:start_link() of
        {ok, Pid} ->
            riak_core:register(riak_core, [{stat_mod, riak_core_stat},
                                           {permissions, [get_bucket,
                                                          set_bucket,
                                                          get_bucket_type,
                                                          set_bucket_type]}]),
            ok = riak_core_ring_events:add_guarded_handler(riak_core_ring_handler, []),

            riak_core_capability:register({riak_core, vnode_routing},
                                          [proxy, legacy],
                                          legacy,
                                          {riak_core,
                                           legacy_vnode_routing,
                                           [{true, legacy}, {false, proxy}]}),
            riak_core_capability:register({riak_core, staged_joins},
                                          [true, false],
                                          false),
            riak_core_capability:register({riak_core, resizable_ring},
                                          [true, false],
                                          false),
            riak_core_capability:register({riak_core, fold_req_version},
                                          [v2, v1],
                                          v1),
            riak_core_capability:register({riak_core, security},
                                          [true, false],
                                          false),
            riak_core_capability:register({riak_core, bucket_types},
                                          [true, false],
                                          false),
            riak_core_capability:register({riak_core, net_ticktime},
                                          [true, false],
                                          false),

            riak_core_cli_registry:load_schema(),
            riak_core_cli_registry:register_node_finder(),
            riak_core_cli_registry:register_cli(),

            riak_core_throttle:init(),

            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

stop(_State) ->
    ?LOG_INFO("Stopped  application riak_core.\n", []),
    ok.
