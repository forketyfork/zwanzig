// EXPECT: none
const c = @cImport(@cInclude("CoreServices/CoreServices.h"));
const source: i32 = 0;
const status = c.TISSelectInputSource(source);

_ = status;
