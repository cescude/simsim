# simsim

Simulate web APIs with a moderate amount of sophistication?

## Synopsis

Define an endpoint that returns a simple JSON response:

    /v1/of/some/api
    {
      "success": true
    }

Define an endpoint that returns non-JSON data:

    /v2/of/some/api
    > Content-type: application/csv
    EOF
    h1,h2,h3
    1,2,3
    4,5,6
    EOF

Note that `EOF` can be anything:

    /v2/of/some/api
    > Content-type: application/csv
    ANYTHING_ELSE
    h1,h2,h3
    1,2,3
    4,5,6
    ANYTHING_ELSE

As in the prior examples, response headers can be supplied with the `>` syntax:

    /v3/of/some/api
    > X-My-Custom-Header: this thing!
    > X-Another-One: agreed!
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

In all, the lua expressions have access to the following variables:

    method (a string)
    uri (a string)
    proto (the protocol)
    body (a string)
    query (a table, contains key/vals corresponding to the http query string)
    form (a table, the result of parsing the request body as x-www-form-encoded)
    json (a table, the result of parsing the request body as JSON)