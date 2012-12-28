%% Feel free to use, reuse and abuse the code in this file.

%% @doc Hello world handler.
-module(wiggle_vm_handler).

-export([init/3,
         rest_init/2]).

-export([content_types_provided/2,
         content_types_accepted/2,
         allowed_methods/2,
         resource_exists/2,
         delete_resource/2,
         forbidden/2,
         post_is_create/2,
         create_path/2,
         options/2,
         is_authorized/2]).

-export([to_json/2,
         from_json/2]).

-ignore_xref([to_json/2,
              from_json/2,
              allowed_methods/2,
              content_types_accepted/2,
              content_types_provided/2,
              delete_resource/2,
              forbidden/2,
              init/3,
              create_path/2,
              post_is_create/2,
              is_authorized/2,
              options/2,
              resource_exists/2,
              rest_init/2]).

-record(state, {path, method, version, token, content, reply}).

init(_Transport, _Req, []) ->
    {upgrade, protocol, cowboy_http_rest}.

rest_init(Req, _) ->
    wiggle_handler:initial_state(Req, <<"vms">>).

options(Req, State) ->
    Methods = allowed_methods(Req, State, State#state.path),
    {ok, Req1} = cowboy_http_req:set_resp_header(
                   <<"Access-Control-Allow-Methods">>,
                   string:join(
                     lists:map(fun erlang:atom_to_list/1,
                               ['HEAD', 'OPTIONS' | Methods]), ", "), Req),
    {ok, Req1, State}.

content_types_provided(Req, State) ->
    {[
      {<<"application/json">>, to_json}
     ], Req, State}.

content_types_accepted(Req, State) ->
    {[
      {<<"application/json; charset=UTF-8">>, from_json}
     ], Req, State}.

post_is_create(Req, State) ->
    {true, Req, State}.

allowed_methods(Req, State) ->
    {['HEAD', 'OPTIONS' | allowed_methods(State#state.version, State#state.token, State#state.path)], Req, State}.

allowed_methods(_Version, _Token, []) ->
    ['GET', 'POST'];

allowed_methods(_Version, _Token, [_Vm]) ->
    ['GET', 'PUT', 'DELETE'].

resource_exists(Req, State = #state{path = []}) ->
    {true, Req, State};

resource_exists(Req, State = #state{path = [Vm]}) ->
    case libsniffle:vm_get(Vm) of
        not_found ->
            {false, Req, State};
        {ok, _} ->
            {true, Req, State}
    end.

is_authorized(Req, State = #state{method = 'OPTIONS'}) ->
    {true, Req, State};

is_authorized(Req, State = #state{token = undefined}) ->
    {{false, <<"X-Snarl-Token">>}, Req, State};

is_authorized(Req, State) ->
    {true, Req, State}.

forbidden(Req, State = #state{method = 'OPTIONS'}) ->
    {false, Req, State};

forbidden(Req, State = #state{token = undefined}) ->
    {true, Req, State};

forbidden(Req, State = #state{method = 'GET', path = []}) ->
    {allowed(State#state.token, [<<"vms">>]), Req, State};

forbidden(Req, State = #state{method = 'POST', path = []}) ->
    {allowed(State#state.token, [<<"vms">>, <<"create">>]), Req, State};

forbidden(Req, State = #state{method = 'GET', path = [Vm]}) ->
    {allowed(State#state.token, [<<"vms">>, Vm, <<"get">>]), Req, State};

forbidden(Req, State = #state{method = 'DELETE', path = [Vm]}) ->
    {allowed(State#state.token, [<<"vms">>, Vm, <<"delete">>]), Req, State};

forbidden(Req, State = #state{method = 'PUT', path = [Vm]}) ->
    {allowed(State#state.token, [<<"vms">>, Vm, <<"edit">>]), Req, State};

forbidden(Req, State) ->
    {true, Req, State}.

%%--------------------------------------------------------------------
%% GET
%%--------------------------------------------------------------------

to_json(Req, State) ->
    {Reply, Req1, State1} = handle_request(Req, State),
    {jsx:encode(Reply), Req1, State1}.

handle_request(Req, State = #state{token = Token, path = []}) ->
    {ok, Permissions} = libsnarl:user_cache({token, Token}),
    {ok, Res} = libsniffle:vm_list([{must, 'allowed', [<<"vm">>, {<<"res">>, <<"uuid">>}, <<"get">>], Permissions}]),
    {lists:map(fun ({E, _}) -> E end,  Res), Req, State};

handle_request(Req, State = #state{path = [Vm]}) ->
    {ok, {vm, Name, _Alias, Hypervisor, _Log, Dict}} = libsniffle:vm_get(Vm),
    {[{<<"uuid">>, Name},
      {<<"hypervisor">>, Hypervisor} | dict:to_list(Dict)], Req, State}.


%%--------------------------------------------------------------------
%% PUT
%%--------------------------------------------------------------------

create_path(Req, State = #state{path = [], version = Version, token = Token}) ->
    {ok, Body, Req1} = cowboy_http_req:body(Req),
    {Decoded, Req2} = case Body of
                          <<>> ->
                              {[], Req1};
                          _ ->
                              D = jsx:decode(Body),
                              {D, Req1}
                      end,
    io:format("~p", [Decoded]),
    {<<"dataset">>, Dataset} = lists:keyfind(<<"dataset">>, 1, Decoded),
    {<<"package">>, Package} = lists:keyfind(<<"package">>, 1, Decoded),
    {<<"config">>, Config} = lists:keyfind(<<"config">>, 1, Decoded),
    {ok, {user, Owner, _, _, _, _}} = libsnarl:user_get({token, Token}),
    {ok, UUID} = libsniffle:create(Package, Dataset, [{<<"owner">>, Owner} | Config]),
    {<<"/api/", Version/binary, "/vms/", UUID/binary>>, Req2, State}.


from_json(Req, State) ->
    {ok, Body, Req1} = cowboy_http_req:body(Req),
    {Reply, Req2, State1} = case Body of
                                <<>> ->
                                    handle_write(Req1, State, []);
                                _ ->
                                    Decoded = jsx:decode(Body),
                                    handle_write(Req1, State, Decoded)
                            end,
    {Reply, Req2, State1}.

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"start">>}]) ->
    libsniffle:vm_start(Vm),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"stop">>}]) ->
    libsniffle:vm_stop(Vm),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"reboot">>}]) ->
    libsniffle:vm_reboot(Vm),
    {true, Req, State};

handle_write(Req, State = #state{path = []}, _Body) ->
    {true, Req, State};

handle_write(Req, State, _Body) ->
    {fase, Req, State}.

%%--------------------------------------------------------------------
%% DEETE
%%--------------------------------------------------------------------

delete_resource(Req, State = #state{path = [Vm]}) ->
    ok = libsniffle:vm_delete(Vm),
    {true, Req, State}.

allowed(Token, Perm) ->
    case libsnarl:allowed({token, Token}, Perm) of
        not_found ->
            true;
        true ->
            false;
        false ->
            true
    end.