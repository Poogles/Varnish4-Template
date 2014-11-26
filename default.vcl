# VCL4 Declaration
vcl 4.0;

# Import VMODS
import std;
import directors;

# Backend Definitions.
backend internal_one {

        .host   = "10.0.0.1";                          # Feel free to use IP's/Hostnames dependening upon use case.
        .port   = "80";
        .probe  =
                {
                .url                            = "/";          # This should be changed to a page which requires all of the app to funciton.
                .timeout                        = 2s;           # This can be tuned to what you feel is suitable.
                .interval                       = 5s;           # Similarly this could be tuned up.
                .window                         = 10;           # Number of checks to determine status.
                .threshold                      = 7;            # Number of checks required to be healthy.
                .initial                        = 7;            # Number of requests initially set so backend starts healthy.
                }
        .connect_timeout                = 1s;
        .between_bytes_timeout  = 1s;

}

backend internal_two {

        .host   = "10.0.0.2";                          # Feel free to use IP's/Hostnames dependening upon use case.
        .port   = "80";
        .probe  =
                {
                .url                            = "/";          # This should be changed to a page which requires all of the app to funciton.
                .timeout                        = 2s;           # This can be tuned to what you feel is suitable.
                .interval                       = 5s;           # Similarly this could be tuned up.
                .window                         = 10;           # Number of checks to determine status.
                .threshold                      = 7;            # Number of checks required to be healthy.
                .initial                        = 7;            # Number of requests initially set so backend starts healthy.
                }
        .connect_timeout                = 1s;
        .between_bytes_timeout  = 1s;

}

backend external {

        .host   = "external-service.com";
        .port   = "80";
        .probe  =
                {
                .url                            = "/";          # This should be the endpoint you hit.
                .timeout                        = 5s;           # This needs to be a bit higher than an internal request.
                .interval                       = 5s;           # Similarly this could be tuned up.
                .window                         = 10;           # Number of checks to determine status.
                .threshold                      = 7;            # Number of checks required to be healthy.
                .initial                        = 7;            # Number of requests initially set so backend starts healthy.
                }
        .connect_timeout                = 1s;
        .between_bytes_timeout  = 1s;

}
sub vcl_init {

        # Add backends to a director using round_robin.
        new cluster1 = directors.round_robin();
        cluster1.add_backend(internal_one);
        cluster1.add_backend(internal_two);

}

acl purge {

        # Setup ACL for purge requests.
        "127.0.0.1";
        "10.0.0.0/24";
        "localhost";

}

sub vcl_recv {

        # All director splits go here, you could split requests depending upon hostname/headers etc.
        # We like to cache external calls, as their slow responses hurt us.
        # If hostname is our external request then pass off to that backend.
        if (req.http.Host == "external-service.com") {
                set req.backend_hint = external;
        }

        # Else set everything to cluster1.
        else  {
                set req.backend_hint = cluster1.backend();
        }

        #Set default grace header
        set req.http.X-Grace = "First Hit";

        # Black Hole /xmlrpc
        if (req.url == "^/xmlrpc") {
                return (synth (601, "Method not allowed."));
        }

        # Allow purging from the purge ACL.
        if (req.method == "PURGE") {
                if (!client.ip ~ purge) {
                        return (synth(405, "AHH AHH AHH, YOU DIDN'T SAY THE MAGIC WORD!"));
                }
                return (purge);
        }

        # Pipe anything that's not normal.
        if (req.method != "GET" &&
                req.method != "HEAD" &&
                req.method != "PUT" &&
                req.method != "POST" &&
                req.method != "TRACE" &&
                req.method != "OPTIONS" &&
                req.method != "PATCH" &&
                req.method != "DELETE") {
                return (pipe);
        }

        # Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
        # We don't really make any POSTs anyway.
        if (req.method != "GET" && req.method != "HEAD") {
                return (pass);
        }


        # Remove all cookies that aren't our OurCookie.
        if (req.http.Cookie) {
                set req.http.Cookie = ";"  + req.http.Cookie;
                set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
                set req.http.Cookie = regsuball(req.http.Cookie, ";(OurCookie)=", "; \1=");
                set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
                set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");
                if (req.http.Cookie == "") {
                        unset req.http.Cookie;
                }
        }

        # Remove facebook strings.
        if (req.url ~ "fb_action_ids") {
                set req.url = regsub(req.url, "(\?|&)\.*$", "");
        }

        # Normalize Accept-Encoding header
        if (req.http.Accept-Encoding) {
                if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
                # Already compressed content...
                unset req.http.Accept-Encoding;
                } elsif (req.http.Accept-Encoding ~ "gzip") {
                        set req.http.Accept-Encoding = "gzip";
                } elsif (req.http.Accept-Encoding ~ "deflate") {
                        set req.http.Accept-Encoding = "deflate";
                } else {
                        # Else...
                        unset req.http.Accept-Encoding;
                }
        }

        # Large static files should be piped, so they are delivered directly to the end-user without delay.
        if (req.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip)(\?.*)?$") {
                return (pipe);
        }


        # Remove all cookies for static files
        if (req.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|pdf|png|rtf|swf|txt|woff|xml)(\?.*)?$") {
                unset req.http.Cookie;
                return (hash);
        }

        return (hash);

}

sub vcl_pipe {

        return (pipe);

}

sub vcl_pass {

        #return (pass);

}

sub vcl_hash {

        # Hash content so we get a seperate cache per cookie.

        # Set a header for debugging.
        set req.http.X-Varnish-Debug-Hash = "URL";

        # Use the cookie as key if a OurCookie cookie has been defined.
        if (req.http.Cookie ~ "OurCookie") {
                set req.http.X-Varnish-Debug-Hash = req.http.X-Varnish-Debug-Hash + "/" + req.http.Cookie;
                hash_data(req.http.cookie);
        # Use predefined cookie set in receive.
        } else {
                if (req.http.X-Predefined-Cookie) {
                        set req.http.X-Varnish-Debug-Hash = req.http.X-Varnish-Debug-Hash + "/(predefined)" + req.http.X-Predefined-Cookie;
                        hash_data(req.http.X-Predefined-Cookie);
                }
        }


        hash_data(req.url);
        if (req.http.host) {
                set req.http.X-Varnish-Debug-Hash = req.http.X-Varnish-Debug-Hash + "/" + req.http.host;
                hash_data(req.http.host);
        } else {
                set req.http.X-Varnish-Debug-Hash = req.http.X-Varnish-Debug-Hash + "/" + server.ip;
                hash_data(server.ip);
        }

}

sub vcl_hit {

        # Grace debugging.  Add headers depending upon level of grace.
        if (obj.ttl >= 0s) {
                set req.http.X-Grace = "Fresh Hit";
                return (deliver);
        }

        if (std.healthy(req.backend_hint)) {
            if (obj.ttl + 20s > 0s) {
                set req.http.X-Grace = "Stale Hit";
                return (deliver);
            }
            else {
                return (fetch);
            }
        } else {
            if (obj.ttl + obj.grace > 0s) {
                set req.http.X-Grace = "Rotten Hit";
                return (deliver);
            } else {
                return (fetch);
            }
        }
    return (deliver);

}

sub vcl_miss {

    return (fetch);

}

sub vcl_backend_response {

        # Set global TTL.
        set beresp.ttl = 5m;
        # Set grace period.
        set beresp.grace = 3h;

        # Unset Cache-Control headers that Tomcat sets.  We'll maintain the TTL inside Varnish.
        unset beresp.http.Cache-Control;

        # Remove all cookies.
        unset beresp.http.set-cookie;

        # Add a header identifying origin server.
        set beresp.http.X-Backend = beresp.backend.name;

        # Set custom static TTL.
        if (bereq.url ~ "^[^?]*\.(jpeg|jpg|gif|png|ico|)(\?.*)?$") {
            set beresp.ttl = 3h;
            set beresp.http.Cache-Control = "Max-Age=10800";
        }

        # Set custom static TTL.
        if (bereq.url ~ "^[^?]*\.(js|css|xml|txt)(\?.*)?$") {
            set beresp.ttl = 1h;
            set beresp.http.Cache-Control = "Max-Age=3600";
        }

        # Set default cacheing for static folders.
        if (bereq.url ~ "/static") {
            set beresp.http.cache-control = "max-age=3600";
            set beresp.ttl = 1h;
        }

        # Set short TTL for homepages.
        if (bereq.url == "/") {
            set beresp.http.cache-control = "max-age=300";
            set beresp.ttl = 5m;
        }

        # Cache 404's to prevent clickspam.
        if (beresp.status == 404) {
            set beresp.http.Cache-Control = "max-age=300";
            set beresp.ttl = 15m;
        }

        #############################################
        #####  MORE CUSTOM TTLS CAN BE SET HERE #####
        #############################################

    return (deliver);

}

sub vcl_deliver {

        # Add cache hit header.  Usefull if you use teired cacheing.
        if (obj.hits > 0) {
        set resp.http.X-Cache-Origin = "HIT";
        } else {
        set resp.http.X-Cache-Origin = "MISS";
        }

        # Add origin server header.  Add your hostname here.
        set resp.http.X-Origin-Server = "webcache-origin";

        # Copy req object to response.
        set resp.http.X-Grace = req.http.X-Grace;

        # Unset age header and add X-Age to response.
        set resp.http.X-Age = resp.http.Age;
        unset resp.http.Age;

    return (deliver);
}

sub vcl_backend_error {


        return (retry);

}

sub vcl_synth {

        # Custom 503 errors can be set here.

        return (deliver);

}

sub vcl_init {

        return (ok);

}

sub vcl_fini {

        return (ok);

}
