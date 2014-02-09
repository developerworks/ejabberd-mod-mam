%%%----------------------------------------------------------------------
%%% File    : mod_mam.erl
%%% Author  : Gregor Uhlenheuer <kongo2002@gmail.com>
%%% Purpose : Message Archive Management (XEP-0313)
%%% Created : 29 Jan 2014 by Gregor Uhlenheuer <kongo2002@gmail.com>
%%%
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%----------------------------------------------------------------------

-module(mod_mam).
-author('kongo2002@googlemail.com').

-behaviour(gen_server).
-behaviour(gen_mod).


-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").


%% API
-export([start_link/2,
         start/2,
         stop/1,
         send_packet/3,
         receive_packet/4,
         get_disco_features/5,
         process_iq/3,
         process_local_iq/3
        ]).


%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(PROCNAME, ejabberd_mod_mam).
-define(POOL_SIZE, 10).
-define(MAX_QUERY_LIMIT, 50).

-define(NS_MAM, <<"urn:xmpp:mam:tmp">>).

-define(MAM_POLICY_VIOLATION(Text),
        #xmlel{name = <<"iq">>,
               attrs = [{<<"type">>, <<"error">>}],
               children =
               [#xmlel{name = <<"error">>,
                       attrs = [{<<"type">>, <<"modify">>}],
                       children = [
                                   #xmlel{name = <<"policy-violation">>,
                                          attrs = [{<<"xmlns">>, ?NS_STANZAS}]},
                                   #xmlel{name = <<"text">>,
                                          attrs = [{<<"xmlns">>, ?NS_STANZAS}],
                                          children = [{xmlcdata, Text}]}
                                  ]
                      }
               ]}).

-record(state, {host = <<"">>        :: binary(),
                ignore_chats = false :: boolean(),
                pool}).

-record(rsm, {max = none,
              after_item = none,
              before_item = none,
              index = none}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
    Proc = get_proc(Host),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = get_proc(Host),

    % make sure bson and mongodb are running
    ok = application:ensure_started(bson),
    ok = application:ensure_started(mongodb),

    Child =
        {Proc,
         {?MODULE, start_link, [Host, Opts]},
         permanent,
         1000,
         worker,
         [?MODULE]},

    supervisor:start_child(ejabberd_sup, Child).

stop(Host) ->
    Proc = get_proc(Host),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

send_packet(From, To, Packet) ->
    Host = From#jid.lserver,
    Proc = get_proc(Host),
    gen_server:cast(Proc, {log, to, From#jid.luser, Host, To, Packet}).

receive_packet(_Jid, From, To, Packet) ->
    Host = To#jid.lserver,
    Proc = get_proc(Host),
    gen_server:cast(Proc, {log, from, To#jid.luser, Host, From, Packet}).


%%%-------------------------------------------------------------------
%%% IQ handling callbacks
%%%-------------------------------------------------------------------

process_iq(From, To, IQ) ->
    process_local_iq(From, To, IQ).

process_local_iq(From, To, #iq{sub_el = SubEl} = IQ) ->
    ?INFO_MSG("IQ: ~p", [IQ]),

    Server = From#jid.lserver,
    case lists:member(Server, ?MYHOSTS) of
        false ->
            % wrong server
            IQ#iq{type=error, sub_el=[SubEl, ?ERR_NOT_ALLOWED]};
        true ->
            case SubEl#xmlel.name of
                <<"query">> ->
                    Proc = get_proc(Server),
                    gen_server:cast(Proc, {process_query, From, To, IQ}),

                    % we have to delay the response IQ until
                    % all messages are sent to the client
                    ignore;
                _ ->
                    % we do not support anything other than 'query'
                    IQ#iq{type = error,
                          sub_el = [SubEl, ?ERR_FEATURE_NOT_IMPLEMENTED]}
            end
    end.


%%%-------------------------------------------------------------------
%%% Service discovery
%%%-------------------------------------------------------------------

get_disco_features(Acc, _From, _To, <<"">>, _Lang) ->
    Features = case Acc of
                   {result, I} -> I;
                   _ -> []
               end,

    {result, Features ++ [?NS_MAM]};

get_disco_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Host, Opts]) ->
    ?INFO_MSG("Starting mod_mam module of '~s'", [Host]),

    IQDisc = gen_mod:get_opt(iqdisc, Opts, false, one_queue),
    IgnoreChats = gen_mod:get_opt(ignore_chats, Opts, false, false),
    MongoConn = gen_mod:get_opt(mongo, Opts,
                                fun ({H, P}) -> {H, P} end,
                                {localhost, 27017}),

    % hook into send/receive packet
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, send_packet, 80),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, receive_packet, 80),
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE, get_disco_features, 99),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, get_disco_features, 99),

    % hook into IQ stanzas
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_MAM, ?MODULE,
                                  process_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_MAM, ?MODULE,
                                  process_local_iq, IQDisc),

    MPool = resource_pool:new(mongo:connect_factory(MongoConn), ?POOL_SIZE),

    {ok, #state{host = Host,
                ignore_chats = IgnoreChats,
                pool = MPool}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({process_query, From, To, #iq{sub_el = Query} = IQ}, State) ->
    Children = Query#xmlel.children,
    NoFilter = {undefined, undefined, undefined, #rsm{}},
    case lists:foldl(fun process_filter/2, NoFilter, Children) of
        {error, E} ->
            Error = IQ#iq{type = error, sub_el = [Query, E]},
            ErrXml = jlib:iq_to_xml(Error),
            ejabberd_router:route(To, From, ErrXml);
        {S, E, J, RSM} ->
            ?INFO_MSG("Filter: ~p", [{S, E, J, RSM}]),
            User = From#jid.luser,
            Pool = State#state.pool,
            QueryId = xml:get_tag_attr_s(<<"queryid">>, Query),
            Fs = [{start, S}, {'end', E}],

            case find(Pool, User, Fs, RSM) of
                {error, Error} ->
                    ejabberd_router:route(To, From, Error);
                Ms when is_list(Ms) ->
                    ?INFO_MSG("Messages: ~p", [Ms]),
                    spawn(fun() -> query_response(Ms, To, From, QueryId) end)
            end
    end,

    {noreply, State};

handle_cast({log, Dir, LUser, LServer, Jid, Packet}, State) ->
    ?INFO_MSG("Packet: ~p", [Packet]),
    case should_store(LUser, LServer) of
        true ->
            IgnoreChats = State#state.ignore_chats,
            case extract_body(Packet, IgnoreChats) of
                ignore -> ok;
                Body ->
                    Pool = State#state.pool,
                    Doc = msg_to_bson(Dir, LUser, LServer, Jid, Body, Packet),
                    insert(Pool, Doc)
            end;
        false -> ok
    end,

    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    Host = State#state.host,
    Pool = State#state.pool,

    ?INFO_MSG("Stopping mod_mam module of '~s'", [Host]),

    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, send_packet, 80),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, receive_packet, 80),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, get_disco_features, 99),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, get_disco_features, 99),

    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM),

    resource_pool:close(Pool),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

should_store(_User, _Server) ->
    % TODO
    true.

extract_body(#xmlel{name = <<"message">>} = Xml, IgnoreChats) ->
    % archive messages with a body tag only
    case xml:get_subtag(Xml, <<"body">>) of
        false -> ignore;
        Body ->
            case IgnoreChats of
                true ->
                    % do not archive groupchat messages
                    case xml:get_tag_attr(<<"type">>, Xml) of
                        {value, <<"groupchat">>} -> ignore;
                        _ -> xml:get_tag_cdata(Body)
                    end;
                _ -> xml:get_tag_cdata(Body)
            end
    end;

extract_body(_, _) -> ignore.

int_cdata(Tag) ->
    CD = xml:get_tag_cdata(Tag),
    case catch binary_to_integer(CD) of
        I when is_integer(I) -> I;
        _ -> error
    end.

parse_rsm(_, error) -> error;
parse_rsm([], RSM) -> RSM;
parse_rsm([#xmlel{name = Name} = C | Cs], RSM) ->
    Result = case Name of
        <<"max">> ->
            case int_cdata(C) of
                error -> error;
                Max -> RSM#rsm{max = Max}
            end;
        <<"after">> ->
            case xml:get_tag_cdata(C) of
                <<"">> -> error;
                CD -> RSM#rsm{after_item = CD}
            end;
        <<"before">> ->
            case xml:get_tag_cdata(C) of
                <<"">> -> error;
                CD -> RSM#rsm{before_item = CD}
            end;
        <<"index">> ->
            case xml:get_tag_cdata(C) of
                <<"">> -> error;
                CD -> RSM#rsm{index = CD}
            end;
        _ -> error
    end,

    parse_rsm(Cs, Result);
parse_rsm([_ | Cs], RSM) -> parse_rsm(Cs, RSM).

get_limit(#rsm{max = M}) ->
    case M of
        Max when is_integer(Max), Max =< ?MAX_QUERY_LIMIT -> {true, Max};
        _ -> {false, ?MAX_QUERY_LIMIT}
    end.

process_filter(_, {error, _E} = Error) -> Error;

process_filter(#xmlel{name = <<"start">>} = Q, {S, E, J, RSM}) ->
    Time = xml:get_tag_cdata(Q),
    case {S, jlib:datetime_string_to_timestamp(Time)} of
        {_, undefined} -> {error, ?ERR_BAD_REQUEST};
        % 'start' tag may be defined only once
        {undefined, Value} -> {Value, E, J, RSM};
        _ -> {error, ?ERR_BAD_REQUEST}
    end;

process_filter(#xmlel{name = <<"end">>} = Q, {S, E, J, RSM}) ->
    Time = xml:get_tag_cdata(Q),
    case {E, jlib:datetime_string_to_timestamp(Time)} of
        {_, undefined} -> {error, ?ERR_BAD_REQUEST};
        % 'end' tag may be defined only once
        {undefined, Value} -> {S, Value, J, RSM};
        _ -> {error, ?ERR_BAD_REQUEST}
    end;

process_filter(#xmlel{name = <<"set">>} = Q, {S, E, J, RSM}) ->
    % search for a RSM (XEP-0059) query statement
    case xml:get_tag_attr_s(<<"xmlns">>, Q) of
        ?NS_RSM ->
            Children = Q#xmlel.children,
            case parse_rsm(Children, RSM) of
                error -> {error, ?ERR_BAD_REQUEST};
                NRSM -> {S, E, J, NRSM}
            end;
        _ ->
            % unknown/invalid 'set' statement
            {error, ?ERR_BAD_REQUEST}
    end;

process_filter(_, Filter) -> Filter.

query_response(Messages, From, To, QueryId) ->
    Attr = [{<<"to">>, jlib:jid_to_string(To)}],
    Send = fun (Message) ->
                   case bson_to_msg(Message, QueryId) of
                       none -> ok;
                       M ->
                           Xml = #xmlel{name = <<"message">>,
                                        attrs = Attr,
                                        children = [M]},
                           ?INFO_MSG("Response: ~p", [Xml]),
                           ejabberd_router:route(From, To, Xml)
                   end
           end,
    lists:foreach(Send, Messages),

    %TODO: terminating IQ stanza
    ok.

get_proc(Host) ->
    gen_mod:get_module_proc(Host, ?PROCNAME).

%%%-------------------------------------------------------------------
%%% MongoDB functions
%%%-------------------------------------------------------------------

get_jid_document(Jid) ->
    {U, S, R} = jlib:jid_tolower(Jid),
    case R of
        <<"">> -> {user, U, server, S};
        _  -> {user, U, server, S, resource, R}
    end.

msg_to_bson(Dir, LUser, LServer, Jid, Body, Xml) ->
    { user, LUser,
      server, LServer,
      jid, get_jid_document(Jid),
      body, Body,
      direction, Dir,
      ts, bson:timenow(),
      raw, xml:element_to_binary(Xml)
    }.

bson_to_msg(Bson, QueryId) ->
    case Bson of
        {'_id', Id, raw, Raw, ts, Ts} ->
            bson_to_msg(Id, Raw, Ts, QueryId);
        {'_id', Id, ts, Ts, raw, Raw} ->
            bson_to_msg(Id, Raw, Ts, QueryId);
        _ -> none
    end.

bson_to_msg(Id, Raw, Ts, QueryId) ->
    case xml_stream:parse_element(Raw) of
        {error, _Error} -> none;
        Xml ->
            Attrs = [{<<"xmlns">>, ?NS_MAM},
                     {<<"id">>, objectid_to_binary(Id)}],

            % add 'queryid' if specified
            As = case QueryId of
                     <<"">> -> Attrs;
                     QId -> [{<<"queryid">>, QId} | Attrs]
                 end,

            % build 'delay' node
            UTC = calendar:now_to_universal_time(Ts),
            {Time, TZ} = jlib:timestamp_to_iso(UTC, utc),
            Stamp = <<Time/binary, TZ/binary>>,
            Delay = #xmlel{name = <<"delay">>,
                           attrs = [{<<"xmlns">>, ?NS_DELAY},
                                    {<<"stamp">>, Stamp}]},

            #xmlel{name = <<"result">>, attrs = As,
                   children = [ #xmlel{name = <<"forwarded">>,
                                       attrs = [{<<"xmlns">>, <<"urn:xmpp:forward:0">>}],
                                       children = [Delay, Xml]}
                              ]}
    end.

objectid_to_binary({Id}) -> objectid_to_binary(Id, []).

objectid_to_binary(<<>>, Result) ->
    list_to_binary(lists:reverse(Result));
objectid_to_binary(<<Hex:8, Bin/binary>>, Result) ->
    SL1 = erlang:integer_to_list(Hex, 16),
    SL2 = case erlang:length(SL1) of
        1 -> ["0"|SL1];
        _ -> SL1
    end,
    objectid_to_binary(Bin, [SL2|Result]).


to_query(_Key, undefined) -> undefined;
to_query(start, Start)    -> {ts, {'$gte', Start}};
to_query('end', End)      -> {ts, {'$lte', End}};
to_query(_Key, _Value)    -> undefined.

add_to_query({_Key, undefined}, Query) -> Query;
add_to_query({Key, X}, Query) ->
    case to_query(Key, X) of
        undefined -> Query;
        Value -> [Value | Query]
    end.

find(Pool, User, Filter, RSM) ->
    BaseQuery = [{user, User}],
    Query = bson:document(lists:foldl(fun add_to_query/2, BaseQuery, Filter)),
    ?INFO_MSG("Query: ~p", [Query]),
    Proj = {'_id', true, raw, true, ts, true},
    Fun = fun () -> mongo:find(messages, Query, Proj) end,

    case exec(Pool, Fun) of
        false -> ok;
        Cursor ->
            case get_limit(RSM) of
                {true, Max} ->
                    mongo:take(Max, Cursor);
                {false, Max} ->
                    Rs = mongo:take(Max+1, Cursor),
                    Len = length(Rs),
                    if Len > Max ->
                           E = ?MAM_POLICY_VIOLATION(<<"Too many results">>),
                           {error, E};
                       true -> Rs
                    end
            end
    end.

insert(Pool, Element) ->
    Fun = fun () -> mongo:insert(messages, Element) end,
    exec(Pool, Fun, unsafe).

exec(Pool, Function) ->
    exec(Pool, Function, safe).

exec(Pool, Function, Mode) ->
    case resource_pool:get(Pool) of
        {ok, Conn} ->
            case mongo:do(Mode, slave_ok, Conn, test, Function) of
                {ok, {}} -> none;
                {ok, {Found}} -> Found;
                {ok, Cursor} -> Cursor
            end;
        {error, _Reason} -> false
    end.


% vim: set et sw=4 sts=4 tw=80:
