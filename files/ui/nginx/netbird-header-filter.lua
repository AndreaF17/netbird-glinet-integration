-- netbird: clear content-length on pages we modify in the body filter.
if ngx.var.uri == "/gl_home.html" or ngx.var.uri == "/" then
    ngx.header.content_length = nil
end
