// What the browser bundles expect of a page and JavaScriptCore does not have: atob
// (markdown-it's copy of entities keeps its decoding tables in base64).
if (typeof atob === "undefined") {
  globalThis.atob = function (input) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const text = String(input).replace(/[\t\n\f\r =]+/g, "");
    let output = "", buffer = 0, bits = 0;
    for (const character of text) {
      const value = alphabet.indexOf(character);
      if (value < 0) throw new Error("atob: not base64");
      buffer = ((buffer << 6) | value) & 0xFFFFFF;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        output += String.fromCharCode((buffer >> bits) & 0xFF);
      }
    }
    return output;
  };
}
