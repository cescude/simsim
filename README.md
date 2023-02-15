# simsim

Simulate REST APIs for development & testing!

## Compiling

Run `zig build` in the root directory to build `simsim`. You'll need a
nightly release as of this writing (2023-02-11), due to the use of
`std.heap.ArenaAllocator.reset(...)`.

## Synopsis

Run simsim. By default, it listens on port `3131` and uses a file
called `payload` to define HTTP endpoints.

    $ simsim --help
    usage: simsim [OPTIONS] [FILE]...
    Maybe an easy to use mocking HTTP server?

    OPTIONS
       -h, --host=STR            Hostname or IP to listen on (defaults to
                                 localhost).
       -p, --port=NUM            Port to listen on (defaults to 3131).
           --help                Show this help message.

    ARGS
       [FILE]                    Files containing payload definitions, processed in
                                 order (default is 'payload').

    $ simsim
    Starting up the server at http://localhost:3131
    Definitions pulled from payload
    ^C

    $ simsim test-case-1 test-case-2 main-definitions
    Starting up the server at http://localhost:3131
    Definitions pulled from test-case-1
    Definitions pulled from test-case-2
    Definitions pulled from main-definitions

Note that the files are reparsed on each request, so you may edit them
while simsim is running and see the results immediately.

## Payload File

Define an endpoint that returns a simple JSON response:

    /v1/of/some/api
    {
      "success": true
    }

Define an endpoint that returns non-JSON data:

    /v2/of/some/api
    Content-type: application/csv
    EOF
    h1,h2,h3
    1,2,3
    4,5,6
    EOF

Note that `EOF` can be anything:

    /v2/of/some/api
    Content-type: application/csv
    ANYTHING_ELSE
    h1,h2,h3
    1,2,3
    4,5,6
    ANYTHING_ELSE

As in the prior examples, response headers can be specified before the
content definition:

    /v3/of/some/api
    X-My-Custom-Header: this thing!
    X-Another-One: agreed!
    { "result": true }

Can use lua to perform additional checks on the request to aid in matching:

    # Could invoke as `curl 'localhost:3131/some/api/favorite_color?user_id=1234'`
    
    /some/api/favorite_color
    @ query.user_id == '1234'
    { "favorite_color": "blue" }

You can chain multiple definitions together to provide default/fallback
endpoints (these are evaluated top to bottom)

    /some/api/favorite_color
    @ query.user_id == '1234'
    { "favorite_color": "blue" }

    /some/api/favorite_color
    { "favorite_color": "who knows?" }

You can return alternate status codes:

    /bad/fail
    500 Internal error
    { "result": false }

    # No body defined on this one
    /flaky/fail
    @ math.random() < 0.3
    500 Internal error

    /flaky/fail
    { "result": true }

Even use status codes to redirect elsewhere:

    /redirect
    307 See other
    Location: http://localhost:3131/some/other/url

If a JSON payload was POST'ed to the endpoint, you can check for that:

    # eg. `curl localhost:3131/some/api/favorite_color --data-raw '{"user_id": 1234}'`
    
    /some/api/favorite_color
    @ json.user_id == 1234
    { "favorite_color": "blue" }

Or if a form has been submitted, you can _also_ check for that:

    # eg. `curl localhost:3131/some/api/favorite_color -d user_id=1234`
    
    /some/api/favorite_color
    @ form.user_id == '1234'
    { "favorite_color": "blue" }

Request headers are stored in a table called `headers`:

    # eg. `curl localhost:3131/some/api -H 'One-Two-Three: Four'`

    /some/api
    @ headers['One-Two-Three'] == 'Four'
    { "result": true }

Alternately, if you're worried about case sensitivity of the provided
header (was it `x-header` or `X-Header`?), CamelCase versions are
provided as well:

    /some/api
    @ headers.OneTwoThree == 'Four'
    { "result": true }
    

If multiple guards are provided, all must match:

    /some/api
    @ 1 == 0 or 2 == 2
    @ true
    @ '2012-01-01' < '2023-01-01'
    { "ok": true }

If you care about the HTTP method, that can be checked as well:

    /some/api
    @ method == 'POST'
    { "type": "Posted" }

    /some/api
    @ method == 'GET'
    { "type": "Getted" }

You can specify wildcards on the path:

    # All three of these definitions are the same!
    
    /some/path
    { "ok", true }

    /*/*
    @ path[0] == '/some/path'
    { "ok", true }

    /*/*
    @ path[1] == 'some'
    @ path[2] == 'path'
    { "ok", true }

Use `**` to match 1+ segments:

    # Could invoke as `curl localhost:3131/one/two/three/four/get/1234`
    /**/get/1234
    { "ok", true }

    # Works as a catch-all rule
    /**
    { "anything": "at all" }

In all, the lua expressions have access to the following variables:

    method  ... a string
    path    ... an array (ok, a table), path[0] is the full path, path[1] is the first segment, etc
    proto   ... a string
    body    ... a string
    headers ... a table, key/vals for each header, plus camel-cased keys
    query   ... a table, contains key/vals corresponding to the http query string
    form    ... a table, the result of parsing the request body as x-www-form-encoded
    json    ... a table, the result of parsing the request body as JSON