// A Node module the battle path never calls. `sim/dex` reaches the config,
// the config reaches the server's half of the project, and that half opens
// sockets and talks to MySQL -- all of it loaded and none of it run. These
// only have to resolve.
module.exports = {};
