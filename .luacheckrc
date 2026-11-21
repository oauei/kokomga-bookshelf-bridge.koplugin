-- Luacheck configuration for Kokomga-Bookshelf Bridge plugin (Lua 5.1 / LuaJIT)
std = "luajit"
max_line_length = false

read_globals = {
    "G_reader_settings",
}

unused_args = true
ignore = {
    "212/_.*",
    "213/_.*",
}
