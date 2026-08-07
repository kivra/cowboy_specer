-module(cowboy_specer_docs_h).
-moduledoc """
Serves the generated OpenAPI document and the two browser UIs.

The document is baked into the route's initial state by
`cowboy_specer:routes/2,3`, so a request does no work beyond writing it out.
The UI pages are a handful of bytes of HTML that load Swagger UI or Redoc from a
CDN and point it at the document's URL -- there is no bundled asset to keep in
step with anything.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-type state() :: {json, binary()} | {swagger | redoc, binary()}.

-spec init(cowboy_req:req(), state()) -> {ok, cowboy_req:req(), state()}.
init(Req0, {json, Json} = State) ->
    Req = cowboy_req:reply(200, #{~"content-type" => ~"application/json"},
                           Json, Req0),
    {ok, Req, State};
init(Req0, {UI, SpecUrl} = State) ->
    Req = cowboy_req:reply(200, #{~"content-type" => ~"text/html; charset=utf-8"},
                           page(UI, SpecUrl), Req0),
    {ok, Req, State}.

page(swagger, SpecUrl) ->
    [~"""
     <!DOCTYPE html>
     <html lang="en">
     <head>
       <meta charset="utf-8">
       <meta name="viewport" content="width=device-width, initial-scale=1">
       <title>API documentation</title>
       <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
     </head>
     <body>
       <div id="swagger-ui"></div>
       <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
       <script>
         window.onload = function () {
           SwaggerUIBundle({
             url: "
     """, SpecUrl, ~"""
     ",
             dom_id: "#swagger-ui",
             deepLinking: true
           });
         };
       </script>
     </body>
     </html>
     """];
page(redoc, SpecUrl) ->
    [~"""
     <!DOCTYPE html>
     <html lang="en">
     <head>
       <meta charset="utf-8">
       <meta name="viewport" content="width=device-width, initial-scale=1">
       <title>API documentation</title>
     </head>
     <body>
       <redoc spec-url="
     """, SpecUrl, ~"""
     "></redoc>
       <script src="https://cdn.jsdelivr.net/npm/redoc/bundles/redoc.standalone.js"></script>
     </body>
     </html>
     """].
