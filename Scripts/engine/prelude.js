// What Node gives the sim, written out for a JavaScript engine that is not
// Node. Only three modules are ever reached for -- `path`, `fs` and one
// `child_process` -- and between them they do four things: join paths, list
// the mods directory, read a couple of text files, and fork a worker the sim
// never forks when it is embedded.
(function () {
  // Read when asked, never captured: the prelude has to be first in the
  // bundle so the data files have their shims when they load, which means it
  // runs before there is any data to hold on to.
  function D() { return globalThis.__psData; }

  // The registry is keyed by the tail of the path the dex computes, because
  // the head is wherever the checkout happened to be.
  function lookup(request) {
    var p = String(request).replace(/\\/g, '/').replace(/\.js$/, '');
    var mod = p.match(/\/data\/mods\/([^/]+)\/([^/]+)$/);
    if (mod) return (D().mods[mod[1]] || {})[mod[2]];
    var base = p.match(/\/data\/([^/]+)$/);
    if (base) return D().base[base[1]];
    if (/\/config\/formats$/.test(p)) return D().formats;
    return undefined;
  }

  globalThis.__psResolve = function (request) {
    var hit = lookup(request);
    if (hit) return hit;
    // The dex asks for files that do not exist and expects to be told so in
    // Node's own words; anything else and it rethrows.
    var err = new Error("Cannot find module '" + request + "'");
    err.code = 'MODULE_NOT_FOUND';
    throw err;
  };

  globalThis.__psPath = {
    resolve: function () {
      var out = '';
      for (var i = 0; i < arguments.length; i++) {
        var part = String(arguments[i]);
        if (part.charAt(0) === '/') out = part;
        else out = out ? out.replace(/\/$/, '') + '/' + part : part;
      }
      // Flatten `a/./b` and `a/b/../c`, which is all the sim ever builds.
      var bits = [];
      out.split('/').forEach(function (bit) {
        if (bit === '.' || bit === '') return;
        if (bit === '..') bits.pop(); else bits.push(bit);
      });
      return '/' + bits.join('/');
    },
    join: function () { return globalThis.__psPath.resolve.apply(null, arguments); },
    dirname: function (p) { return String(p).replace(/\/[^/]*$/, '') || '/'; },
    basename: function (p) { return String(p).replace(/^.*\//, ''); },
    sep: '/',
  };

  globalThis.__psFs = {
    // The only directory the sim lists is the mods folder, to find out which
    // mods exist. It gets the one we shipped.
    readdirSync: function (dir) {
      if (/\/data\/mods$/.test(String(dir).replace(/\\/g, '/'))) return Object.keys(D().mods);
      return [];
    },
    readFileSync: function () { var e = new Error('ENOENT'); e.code = 'ENOENT'; throw e; },
    existsSync: function () { return false; },
    statSync: function () { var e = new Error('ENOENT'); e.code = 'ENOENT'; throw e; },
    writeFileSync: function () {},
  };

  globalThis.__psChildProcess = {
    // The sim forks workers only when it is a server. Embedded, it is not.
    fork: function () { throw new Error('child_process is not available in the embedded engine'); },
  };

  // The sim builds its data paths from __dirname. Any stable root will do:
  // the registry above matches on the tail of the path, never the head.
  globalThis.__dirname = '/showdown/sim';
  globalThis.__filename = '/showdown/sim/index.js';

  // JavaScriptCore has no crypto. The sim only reaches for it to seed a
  // battle when nobody gave it a seed, and a battle here is always seeded --
  // but it reads the global at load time, so it has to be there.
  if (typeof globalThis.crypto === 'undefined') {
    globalThis.crypto = {
      getRandomValues: function (arr) {
        for (var i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 4294967296);
        return arr;
      },
    };
  }

  if (typeof globalThis.process === 'undefined') {
    globalThis.process = {
      env: {}, argv: [], platform: 'darwin', version: 'v22.0.0',
      nextTick: function (fn) { fn(); },
      hrtime: { bigint: function () { return BigInt(Math.round(Date.now() * 1e6)); } },
    };
  }
  if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;
})();
