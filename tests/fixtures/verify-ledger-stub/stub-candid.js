// Offline stub. verify_ledger.mjs only builds IDL descriptors and hands them to
// Actor.createActor, which in this stub ignores them entirely, so every
// constructor can return an inert marker.
const any = () => ({ _idl: true });
export const IDL = {
  Service: any, Func: any, Vec: any, Record: any, Opt: any, Variant: any,
  Tuple: any, Nat: any(), Int: any(), Text: any(), Bool: any(),
  Principal: any(), Nat8: any(), Null: any(),
};
