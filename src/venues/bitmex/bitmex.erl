-module(bitmex).
-behaviour(rest).
-behaviour(websocket_client_handler).
-include("bitmex.hrl").
-include("core.hrl").
-compile(export_all).
-export([init/2,websocket_handle/3,websocket_info/3,websocket_terminate/3]).
-compile({parse_transform, rest}).
-rest_record(bitmex).

name("XBTUSD")    -> bitmex_btc_usd_swap;
name("COIN_BH17") -> bitmex_coin_future;
name("DASH7D")    -> bitmex_dash_future;
name("ETH7D")     -> bitmex_eth_future;
name(tick)        -> tick;
name(X)           -> [].

subscription()    -> [].

route(#bitmex{table="orderBookL2",action=Ac,data=D}=B,M) ->
    lists:foldl(fun (X,A) -> action(order,B,Ac,X,M) end, [], [X||X<-D]);

route(#bitmex{table="trade",action=Ac,data=D}=B,M) ->
    lists:foldl(fun (X,A) -> action(trade,B,Ac,X,M) end, [], [X||X<-D]);

route(A,M) -> kvs:info(?MODULE,"~p ~p~n",[A,M]), [].

action(Stream,T,A,#bsym{symbol=Sym,side=Side,size=S,price=P,timestamp=TS,id=OID}=Packet,Debug) ->
    app:trace(?MODULE,[Stream,A,Sym,S,P,Side,Debug,TS,OID,[]]).

trade(Sym,A,"Buy",S,P,M,O,Q)    -> [trade,P,app:nn(S),bid];
trade(Sym,A,"Sell",S,P,M,O,Q)   -> [trade,P,app:nn(S),ask];
trade(Sym,A,R,S,P,M,O,Q)        -> kvs:info(?MODULE,"Warning. Reason is empty: ~p~n",[{Sym,A,R,S,P,O,Q}]),
                                   [].

order(Sym,"delete",_,S,P,M,O,Q) -> book:del(#tick{sym=name(Sym),id=O});
order(Sym,"update",D,S,P,M,O,Q) -> case book:del(#tick{id=O,sym=name(Sym)}) of
                                        [Price,UID] -> order(Sym,"insert",D,S,Price,M,O,Q);
                                        [] -> [] end;
order(Sym,A,R,S,P,M,O,Q) when S == 0 orelse P == [] ->
    kvs:info(?MODULE,"if it isn't cancel/filled report error: ~p~n",[{A,M}]),
                                   book:del(#tick{sym=name(Sym),id=O});
order(Sym,A,"Buy",S,P,M,O,Q)    -> book:add(#tick{sym=name(Sym),id=O,size=app:nn(S),price=P,side=bid,sn=Q});
order(Sym,A,"Sell",S,P,M,O,Q)   -> book:add(#tick{sym=name(Sym),id=O,size=-app:nn(S),price=P,side=ask,sn=Q}).

state({S,P})      -> {S+1,P}.
instance()        -> #bitmex{}.
post({Data}, Ctx) -> Bitmex=from_json(Data, instance()),
                     Bitmex#bitmex{data=[ bsym:post(I, Ctx) || I <- Bitmex#bitmex.data]}.
print(Msg)        -> try route(post(jsone:decode(Msg),#io{}),Msg)
                     catch E:R -> kvs:info(?MODULE,"Error: ~p~n",[{E,R,Msg,erlang:get_stacktrace()}]) end.

init([P], _)                              -> {ok, {1,P}}.
websocket_info(start, _, State)           -> {reply, <<>>, State};
websocket_info({left, Sym, Pid}, _, S)    -> Pid ! snapshot:sync(bitmex,Sym),  {ok, S};
websocket_info({right, Sym, Pid}, _, S)   -> Pid ! snapshot:check(bitmex,Sym), {ok, S};
websocket_info(start, _, State)           -> {reply, <<>>, State}.
websocket_handle({pong, _}, _, State)     -> {ok, State};
websocket_handle({text, Msg}, _, State)   -> print(Msg), {ok, state(State)};
websocket_handle(Msg, _Conn, State)       -> print(Msg), {noreply, state(State)}.
websocket_terminate(Msg, _, {_,P})        -> kvs:info(?MODULE,"~p terminated. notify ~p~n",[Msg,P]),
                                             erlang:send_after(100,P,{timer,connect,5}), ok.

left_cut(Topic)  -> [].
right_cut(Topic) ->
    Shot = bshot:get(Topic), Name = name(Topic),
    [ order(tick,"book",Side,app:normal(app:p(S)),app:normal(app:p(P)),[],O,kvs:next_id(order,1)) || {_,O,Side,S,P,Sym} <- Shot ],
    {snapshot:book(?MODULE,Topic),snapshot:book(?MODULE,tick),Shot}.

shotlevel(Shot,Price) -> [ [app:normal(app:p(P)),app:normal(app:p(S)),O] || {_,O,Side,S,P,Sym} <- Shot, app:normal(app:p(P)) == Price ].