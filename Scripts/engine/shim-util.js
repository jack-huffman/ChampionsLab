// Node's `util`, as far as the sim reaches into it -- which is one function.
// `dex-species` uses isDeepStrictEqual to decide whether a form really
// differs from the species it came from, so getting it wrong would quietly
// merge or split forms rather than fail loudly.
function isDeepStrictEqual(a, b) {
  if (a === b) return true;
  // The one case where === is wrong in the other direction.
  if (typeof a === 'number' && typeof b === 'number') return a !== a && b !== b;
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false;
  if (Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (!isDeepStrictEqual(a[i], b[i])) return false;
    return true;
  }
  if (a instanceof Date) return a.getTime() === b.getTime();
  if (a instanceof RegExp) return String(a) === String(b);
  if (a instanceof Set) {
    if (a.size !== b.size) return false;
    for (var v of a) if (!b.has(v)) return false;
    return true;
  }
  if (a instanceof Map) {
    if (a.size !== b.size) return false;
    for (var e of a) if (!b.has(e[0]) || !isDeepStrictEqual(e[1], b.get(e[0]))) return false;
    return true;
  }
  var ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (var j = 0; j < ka.length; j++) {
    if (!Object.prototype.hasOwnProperty.call(b, ka[j])) return false;
    if (!isDeepStrictEqual(a[ka[j]], b[ka[j]])) return false;
  }
  return true;
}
module.exports = { isDeepStrictEqual: isDeepStrictEqual, inspect: function (x) { return String(x); } };
