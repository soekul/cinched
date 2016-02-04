%%%-------------------------------------------------------------------
%%% @author Mark Steele <mark@control-alt-del.org>
%%% @copyright (C) 2016, Mark Steele
%%% @doc
%%% Cinched BLOB REST API
%%% @end
%%% Created : 24 Jan 2016 by Mark Steele <mark@control-alt-del.org>
%%%-------------------------------------------------------------------
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
-module(cinched_crypto_blob_rest_handler).

-include("cinched.hrl").

%% Callbacks for REST API
-export([init/3, known_methods/2,
         allowed_methods/2,rest_init/2,
         content_types_provided/2, is_authorized/2,
         content_types_accepted/2]).

%% Custom functions
-export([encrypt/2, decrypt/2]).

-record(state,{action}).

-spec init(_,_,_) -> {'upgrade','protocol','cowboy_rest'}.
init(_Transport, _Req, _Args) ->
  {upgrade, protocol, cowboy_rest}.

-spec rest_init(_,_) -> {ok,any(),any()} | {halt,any(),undefined}.
rest_init(Req, _Opts) ->
  case cowboy_req:binding(action, Req) of
    {Action, Req} ->
      {ok, Req, #state{action=Action}};
    {undefined, Req}  ->
      {halt,Req,undefined}
  end.

-spec known_methods(_,_) -> {[<<_:32>>,...],_,_}.
known_methods(Req, Ctx) ->
  {[<<"POST">>], Req, Ctx}.

-spec allowed_methods(_,_) -> {[<<_:32>>,...],_,_}.
allowed_methods(Req, Ctx) ->
  {[<<"POST">>], Req, Ctx}.

-spec is_authorized(_,_) -> {true,any(),any()}.
is_authorized(Req,Ctx) ->
  {true, Req, Ctx}.

-spec content_types_provided(_,_) -> {[{{_,_,_},'encrypt'},...],_,_}.
content_types_provided(Req, Ctx=#state{action=Action}) ->
  case Action of
    <<"encrypt">> ->
      {[{{<<"application">>, <<"octet-stream">>, '*'}, encrypt}], Req, Ctx};
    <<"decrypt">> ->
      {[{{<<"application">>, <<"octet-stream">>, '*'}, decrypt}], Req, Ctx}
  end.

-spec content_types_accepted(_,_) -> {[{{_,_,_},'encrypt'},...],_,_}.
content_types_accepted(Req, Ctx=#state{action=Action}) ->
  case Action of
    <<"encrypt">> ->
      {[{{<<"application">>, <<"octet-stream">>, '*'}, encrypt}], Req, Ctx};
    <<"decrypt">> ->
      {[{{<<"application">>, <<"octet-stream">>, '*'}, decrypt}], Req, Ctx}
  end.

-spec encrypt(_,_) -> {'true',_,{}}.
encrypt(Req, _Ctx) ->
  {ok, Body, _Req1} = cowboy_req:body(Req,[]),
  {ok, DataKey} = case cowboy_req:header(<<"x-cinched-data-key">>, Req) of
                    {undefined,_} ->
                      cinched:generate_data_key();
                    {KeyHeader,_} ->
                      {ok, binary_to_term(base64:decode(KeyHeader))}
                  end,
  {Time, Value} = timer:tc(
                    fun() ->
                        poolboy:transaction(
                          pb,
                          fun(Worker) ->
                              gen_server:call(Worker,{encrypt,DataKey,Body})
                          end
                         )
                    end
                   ),

  %% Gather logging data
  {Peer,Port0} = cowboy_req:get(peer,Req),
  Port = integer_to_binary(Port0),
  PeerIP = list_to_binary(inet_parse:ntoa(Peer)),
  {ok,{Serial,PeerCN}} = cinched:get_cert_info_from_socket(cowboy_req:get(socket,Req)),
  {QueryString,_} = cowboy_req:qs(Req),
  {UserAgent,_} = cowboy_req:header(<<"user-agent">>,Req),
  {Metadata,_} = cowboy_req:header(<<"x-cinched-metadata">>,Req),

  exometer:update([crypto_worker,encrypt,time],Time),
  case Value of
    {ok, Response} ->
      cinched_log:log([
                       {op,blob_encrypt},
                       {status,ok},
                       {meta,Metadata},
                       {query_string,QueryString},
                       {user_agent,UserAgent},
                       {peer_ip,PeerIP},
                       {peer_port,Port},
                       {peer_cert_cn,PeerCN},
                       {peer_cert_serial,Serial}
                      ]),
      Req0 = cowboy_req:set_resp_header(
               <<"x-cinched-data-key">>,
               base64:encode(term_to_binary(DataKey)),
               Req
              ),
      Req1 = cowboy_req:set_resp_header(
               <<"x-cinched-crypto-period">>,
               integer_to_binary(DataKey#cinched_key.crypto_period),
               Req0
              ),
      exometer:update([api,blob,encrypt,ok],1),
      {true, cowboy_req:set_resp_body(Response, Req1), {}};
    {error,_Err} ->
      cinched_log:log([
                       {op,blob_encrypt},
                       {status,error},
                       {meta,Metadata},
                       {query_string,QueryString},
                       {user_agent,UserAgent},
                       {peer_ip,PeerIP},
                       {peer_port,Port},
                       {peer_cert_cn,PeerCN},
                       {peer_cert_serial,Serial}
                      ]),
      exometer:update([api,blob,encrypt,error],1),
      {false, Req, {}}
  end.

-spec decrypt(_,_) -> {'true',_,{}}.
decrypt(Req, _Ctx) ->
  {ok, Body, _Req1} = cowboy_req:body(Req,[]),
  {ok, DataKey} = case cowboy_req:header(<<"x-cinched-data-key">>, Req) of
                    {undefined,_} ->
                      throw("Error, missing data key");
                    {KeyHeader,_} ->
                      {ok, binary_to_term(base64:decode(KeyHeader))}
                  end,
  {Time, Value} = timer:tc(
                    fun() ->
                        poolboy:transaction(
                          pb,
                          fun(Worker) ->
                              gen_server:call(Worker,{decrypt,DataKey,Body})
                          end
                         )
                    end
                   ),
  exometer:update([crypto_worker,decrypt,time],Time),

  %% Gather logging data
  {Peer,Port0} = cowboy_req:get(peer,Req),
  Port = integer_to_binary(Port0),
  PeerIP = list_to_binary(inet_parse:ntoa(Peer)),
  {ok,{Serial,PeerCN}} = cinched:get_cert_info_from_socket(cowboy_req:get(socket,Req)),
  {QueryString,_} = cowboy_req:qs(Req),
  {UserAgent,_} = cowboy_req:header(<<"user-agent">>,Req),
  {Metadata,_} = cowboy_req:header(<<"x-cinched-metadata">>,Req),

  case Value of
    {ok, Response} ->
      cinched_log:log([
                       {op,blob_decrypt},
                       {status,ok},
                       {meta,Metadata},
                       {query_string,QueryString},
                       {user_agent,UserAgent},
                       {peer_ip,PeerIP},
                       {peer_port,Port},
                       {peer_cert_cn,PeerCN},
                       {peer_cert_serial,Serial}
                      ]),
      exometer:update([api,blob,decrypt,ok],1),
      {true,cowboy_req:set_resp_body(Response,Req), {}};
    {error,_} ->
      cinched_log:log([
                       {op,blob_decrypt},
                       {status,error},
                       {meta,Metadata},
                       {query_string,QueryString},
                       {user_agent,UserAgent},
                       {peer_ip,PeerIP},
                       {peer_port,Port},
                       {peer_cert_cn,PeerCN},
                       {peer_cert_serial,Serial}

                      ]),
      exometer:update([api,blob,decrypt,error],1),
      {false, Req, {}}
  end.
