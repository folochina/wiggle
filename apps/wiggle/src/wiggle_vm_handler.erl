-module(wiggle_vm_handler).

-include("wiggle.hrl").

-export([allowed_methods/3,
         get/1,
         permission_required/1,
         handle_request/2,
         create_path/3,
         handle_write/3,
         delete_resource/2]).

-ignore_xref([allowed_methods/3,
              get/1,
              permission_required/1,
              handle_request/2,
              create_path/3,
              handle_write/3,
              delete_resource/2]).

allowed_methods(_Version, _Token, []) ->
    [<<"GET">>, <<"POST">>];

allowed_methods(_Version, _Token, [_Vm]) ->
    [<<"GET">>, <<"PUT">>, <<"DELETE">>];

allowed_methods(_Version, _Token, [_Vm, <<"metadata">>|_]) ->
    [<<"PUT">>, <<"DELETE">>];

allowed_methods(_Version, _Token, [_Vm, <<"nics">>, _Mac]) ->
    [<<"PUT">>, <<"DELETE">>];

allowed_methods(_Version, _Token, [_Vm, <<"nics">>]) ->
    [<<"POST">>];

allowed_methods(_Version, _Token, [_Vm, <<"snapshots">>, _ID]) ->
    [<<"GET">>, <<"PUT">>, <<"DELETE">>];

allowed_methods(_Version, _Token, [_Vm, <<"snapshots">>]) ->
    [<<"GET">>, <<"POST">>].

get(State = #state{path = [Vm, <<"snapshots">>, Snap]}) ->
    case wiggle_vm_handler:get(State#state{path=[Vm]}) of
        {ok, Obj} ->
            case jsxd:get([<<"snapshots">>, Snap], Obj) of
                undefined -> not_found;
                {ok, _} -> {ok, Obj}
            end;
        E ->
            E
    end;

get(State = #state{path = [Vm, <<"nics">>, Mac]}) ->
    case wiggle_vm_handler:get(State#state{path=[Vm]}) of
        {ok, Obj} ->
            Macs = [jsxd:get([<<"mac">>], <<>>, N) ||
                       N <- jsxd:get([<<"config">>, <<"networks">>], [], Obj)],
            case lists:member(Mac, Macs) of
                true ->
                    {ok, Obj};
                _ ->
                    not_found
            end;
        E ->
            E
    end;

get(State = #state{path = [Vm | _]}) ->
    Start = now(),
    R = libsniffle:vm_get(Vm),
    ?MSniffle(?P(State), Start),
    R.

permission_required(#state{method = <<"GET">>, path = []}) ->
    {ok, [<<"cloud">>, <<"vms">>, <<"list">>]};

permission_required(#state{method = <<"POST">>, path = []}) ->
    {ok, [<<"cloud">>, <<"vms">>, <<"create">>]};

permission_required(#state{method = <<"GET">>, path = [Vm]}) ->
    {ok, [<<"vms">>, Vm, <<"get">>]};

permission_required(#state{method = <<"DELETE">>, path = [Vm]}) ->
    {ok, [<<"vms">>, Vm, <<"delete">>]};

permission_required(#state{method = <<"POST">>, path = [Vm, <<"nics">>]}) ->
    {ok, [<<"vms">>, Vm, <<"edit">>]};

permission_required(#state{method = <<"PUT">>, path = [Vm, <<"nics">>, _]}) ->
    {ok, [<<"vms">>, Vm, <<"edit">>]};

permission_required(#state{method = <<"DELETE">>, path = [Vm, <<"nics">>, _]}) ->
    {ok, [<<"vms">>, Vm, <<"edit">>]};

permission_required(#state{method = <<"GET">>, path = [Vm, <<"snapshots">>]}) ->
    {ok, [<<"vms">>, Vm, <<"get">>]};

permission_required(#state{method = <<"POST">>, path = [Vm, <<"snapshots">>]}) ->
    {ok, [<<"vms">>, Vm, <<"snapshot">>]};

permission_required(#state{method = <<"GET">>, path = [Vm, <<"snapshots">>, _Snap]}) ->
    {ok, [<<"vms">>, Vm, <<"get">>]};

permission_required(#state{method = <<"PUT">>, body = undefiend}) ->
    {error, needs_decode};

permission_required(#state{method = <<"PUT">>, body = Decoded, path = [Vm]}) ->
    case Decoded of
        [{<<"action">>, Act}] ->
            {ok, [<<"vms">>, Vm, Act]};
        _ ->
            {ok, [<<"vms">>, Vm, <<"edit">>]}
    end;

permission_required(#state{method = <<"PUT">>, body = Decoded,
                           path = [Vm, <<"snapshots">>, _Snap]}) ->
    case Decoded of
        [{<<"action">>, <<"rollback">>}] ->
            {ok, [<<"vms">>, Vm, <<"rollback">>]};
        _ ->
            {ok, [<<"vms">>, Vm, <<"edit">>]}
    end;

permission_required(#state{method = <<"PUT">>,
                           path = [Vm, <<"metadata">> | _]}) ->
    {ok, [<<"vms">>, Vm, <<"edit">>]};

permission_required(#state{method = <<"DELETE">>, path = [Vm, <<"snapshots">>, _Snap]}) ->
    {ok, [<<"vms">>, Vm, <<"snapshot_delete">>]};

permission_required(#state{method = <<"DELETE">>, path = [Vm, <<"metadata">> | _]}) ->
    {ok, [<<"vms">>, Vm, <<"edit">>]};

permission_required(_State) ->
    undefined.

%%--------------------------------------------------------------------
%% GET
%%--------------------------------------------------------------------

handle_request(Req, State = #state{token = Token, path = []}) ->
    Start = now(),
    {ok, Permissions} = libsnarl:user_cache({token, Token}),
    ?MSnarl(?P(State), Start),
    Start1 = now(),
    {ok, Res} = libsniffle:vm_list([{must, 'allowed', [<<"vms">>, {<<"res">>, <<"uuid">>}, <<"get">>], Permissions}]),
    ?MSniffle(?P(State), Start1),
    {lists:map(fun ({E, _}) -> E end,  Res), Req, State};

handle_request(Req, State = #state{path = [_Vm, <<"snapshots">>], obj = Obj}) ->
    Snaps = jsxd:fold(fun(UUID, Snap, Acc) ->
                              [jsxd:set(<<"uuid">>, UUID, Snap) | Acc]
                      end, [], jsxd:get(<<"snapshots">>, [], Obj)),
    {Snaps, Req, State};

handle_request(Req, State = #state{path = [_Vm, <<"snapshots">>, Snap], obj = Obj}) ->
    {jsxd:get([<<"snapshots">>, Snap], null, Obj), Req, State};

handle_request(Req, State = #state{path = [_Vm], obj = Obj}) ->
    {Obj, Req, State}.

%%--------------------------------------------------------------------
%% PUT
%%--------------------------------------------------------------------

create_path(Req, State = #state{path = [], version = Version, token = Token}, Decoded) ->
    try
        {ok, Dataset} = jsxd:get(<<"dataset">>, Decoded),
        {ok, Package} = jsxd:get(<<"package">>, Decoded),
        {ok, Config} = jsxd:get(<<"config">>, Decoded),
        try
            {ok, User} = libsnarl:user_get({token, Token}),
            {ok, Owner} = jsxd:get(<<"uuid">>, User),
            Start = now(),
            {ok, UUID} = libsniffle:create(Package, Dataset, jsxd:set(<<"owner">>, Owner, Config)),
            ?MSniffle(?P(State), Start),
            {<<"/api/", Version/binary, "/vms/", UUID/binary>>, Req, State#state{body = Decoded}}
        catch
            G:E ->
                lager:error("Error creating VM(~p): ~p / ~p", [Decoded, G, E]),
                {ok, Req1} = cowboy_req:reply(500, Req),
                {halt, Req1, State}
        end
    catch
        G1:E1 ->
            lager:error("Error creating VM(~p): ~p / ~p", [Decoded, G1, E1]),
            {ok, Req2} = cowboy_req:reply(400, Req),
            {halt, Req2, State}
    end;

create_path(Req, State = #state{path = [Vm, <<"snapshots">>], version = Version}, Decoded) ->
    Comment = jsxd:get(<<"comment">>, <<"">>, Decoded),
    Start = now(),
    {ok, UUID} = libsniffle:vm_snapshot(Vm, Comment),
    ?MSniffle(?P(State), Start),
    {<<"/api/", Version/binary, "/vms/", Vm/binary, "/snapshots/", UUID/binary>>, Req, State#state{body = Decoded}};
create_path(Req, State = #state{path = [Vm, <<"nics">>], version = Version}, Decoded) ->
    {ok, Network} = jsxd:get(<<"network">>, Decoded),
    Start = now(),
    ok = libsniffle:vm_add_nic(Vm, Network),
    ?MSniffle(?P(State), Start),
    {<<"/api/", Version/binary, "/vms/", Vm/binary>>, Req, State#state{body = Decoded}}.


handle_write(Req, State = #state{path = [_, <<"nics">>]}, _Body) ->
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm, <<"nics">>, Mac]}, [{<<"primary">>, true}]) ->
    Start = now(),
    ok = libsniffle:vm_primary_nic(Vm, Mac),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm, <<"metadata">> | Path]}, [{K, V}]) ->
    Start = now(),
    libsniffle:vm_set(Vm, [<<"metadata">> | Path] ++ [K], jsxd:from_list(V)),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"start">>}]) ->
    Start = now(),
    libsniffle:vm_start(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"stop">>}]) ->
    Start = now(),
    libsniffle:vm_stop(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"stop">>}, {<<"force">>, true}]) ->
    Start = now(),
    libsniffle:vm_stop(Vm, [force]),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"reboot">>}]) ->
    Start = now(),
    libsniffle:vm_reboot(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"action">>, <<"reboot">>}, {<<"force">>, true}]) ->
    Start = now(),
    libsniffle:vm_reboot(Vm, [force]),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"config">>, Config},
                                                {<<"package">>, Package}]) ->
    Start = now(),
    libsniffle:vm_update(Vm, Package, Config),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"config">>, Config}]) ->
    Start = now(),
    libsniffle:vm_update(Vm, undefined, Config),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm]}, [{<<"package">>, Package}]) ->
    Start = now(),
    libsniffle:vm_update(Vm, Package, []),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State = #state{path = []}, _Body) ->
    {true, Req, State};

handle_write(Req, State = #state{path = [_Vm, <<"snapshots">>]}, _Body) ->
    {true, Req, State};

handle_write(Req, State = #state{path = [Vm, <<"snapshots">>, UUID]}, [{<<"action">>, <<"rollback">>}]) ->
    Start = now(),
    ok = libsniffle:vm_rollback_snapshot(Vm, UUID),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

handle_write(Req, State, _Body) ->
    lager:error("Unknown PUT request: ~p~n.", [State]),
    {false, Req, State}.

%%--------------------------------------------------------------------
%% DEETE
%%--------------------------------------------------------------------

delete_resource(Req, State = #state{path = [Vm, <<"snapshots">>, UUID]}) ->
    Start = now(),
    ok = libsniffle:vm_delete_snapshot(Vm, UUID),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

delete_resource(Req, State = #state{path = [Vm, <<"nics">>, Mac]}) ->
    Start = now(),
    ok = libsniffle:vm_remove_nic(Vm, Mac),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

delete_resource(Req, State = #state{path = [Vm]}) ->
    Start = now(),
    ok = libsniffle:vm_delete(Vm),
    ?MSniffle(?P(State), Start),
    {true, Req, State};

delete_resource(Req, State = #state{path = [Vm, <<"metadata">> | Path]}) ->
    Start = now(),
    libsniffle:vm_set(Vm, [<<"metadata">> | Path], delete),
    ?MSniffle(?P(State), Start),
    {true, Req, State}.
