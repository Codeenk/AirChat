import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha2.js';

// @noble/ed25519 v2 requires an explicit sha512 implementation.
// Wire the sync variant once at module load.
const concatBytes = (...arrays: Uint8Array[]): Uint8Array => {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const a of arrays) {
    out.set(a, offset);
    offset += a.length;
  }
  return out;
};

ed.etc.sha512Sync = (...m) => sha512(concatBytes(...m));
ed.etc.sha512Async = async (...m) => sha512(concatBytes(...m));

export async function verifyEd25519Signature(
  publicKeyHex: string,
  signatureHex: string,
  message: string,
): Promise<boolean> {
  if (!publicKeyHex || !signatureHex || !message) return false;

  try {
    const publicKeyBytes = hexToBytes(publicKeyHex);
    const signatureBytes = hexToBytes(signatureHex);
    const messageBytes = new TextEncoder().encode(message);

    return await ed.verify(signatureBytes, messageBytes, publicKeyBytes);
  } catch {
    return false;
  }
}

function hexToBytes(hex: string): Uint8Array {
  const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
  const bytes = new Uint8Array(cleanHex.length / 2);
  for (let i = 0; i < cleanHex.length; i += 2) {
    bytes[i / 2] = parseInt(cleanHex.substring(i, i + 2), 16);
  }
  return bytes;
}
