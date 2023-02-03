pub const c = @cImport({
    @cInclude("mongoose.h");
    @cInclude("mext.h");
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});
