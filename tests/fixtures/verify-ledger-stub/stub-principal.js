// Offline stub. No network. Only the surface verify_ledger.mjs actually uses.
export class Principal {
  constructor(t) { this._t = t; }
  static fromText(t) { return new Principal(t); }
  toText() { return this._t; }
  toUint8Array() { return new Uint8Array([0xde, 0xad, 0xbe, 0xef]); }
}
