-- netbird: inject script tag into GL admin SPA HTML.
-- {{VERSION}} is substituted by scripts/mkipk.sh at build time; the
-- version-stamped URL forces browsers to refetch after a package upgrade.
if ngx.var.uri == "/gl_home.html" or ngx.var.uri == "/" then
    local chunk = ngx.arg[1]
    if chunk and chunk:find("</head>") then
        ngx.arg[1] = chunk:gsub("</head>",
            '<script defer src="/netbird-ui/netbird.js?v={{VERSION}}"></script></head>', 1)
    end
end
