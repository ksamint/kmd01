import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  authenticatedData,
  decodeSignedDeviceGrant,
  decodeAndVerifySignedManifest,
  decodeVaultObject,
  encodeVaultManifest,
  encodeVaultObject,
  hex,
  hpkeOpenP256,
  hpkeSealP256,
  openVaultObject,
  openVaultPath,
  sealVaultPath,
  signVaultManifest,
  signDeviceGrant,
  sealVaultObject,
  unhex,
  verifySignedDeviceGrant,
  vaultUUIDBytes,
} from './vaultProtocol';

type Vector = {
  masterKeyHex: string;
  fileId: string;
  versionId: string;
  plaintextUtf8: string;
  plaintextSize: number;
  nonceHex: string;
  aadHex: string;
  paddedSize: number;
  ciphertextSha256Hex: string;
  authenticationTagHex: string;
  objectDigestHex: string;
  pathNonceHex: string;
  pathCiphertextHex: string;
  pathAuthenticationTagHex: string;
  manifestCborSha256Hex: string;
};

const vector = JSON.parse(readFileSync(
  new URL('../../../Cloud/test-vectors/vault-object-v1.json', import.meta.url),
  'utf8',
)) as Vector;

describe('VaultObjectV1 cross-language vector', () => {
  it('matches Rust AES-GCM, HKDF, padding and AAD bytes', async () => {
    const plaintext = new TextEncoder().encode(vector.plaintextUtf8);
    const sealed = await sealVaultObject({
      plaintext,
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
      nonce: unhex(vector.nonceHex),
    });
    expect(sealed.paddedSize).toBe(vector.paddedSize);
    expect(hex(sealed.authenticationTag)).toBe(vector.authenticationTagHex);
    expect(hex(new Uint8Array(await crypto.subtle.digest(
      'SHA-256',
      sealed.ciphertext.slice().buffer as ArrayBuffer,
    ))))
      .toBe(vector.ciphertextSha256Hex);
    expect(hex(authenticatedData({
      fileId: vector.fileId,
      versionId: vector.versionId,
      kind: 'markdown',
      mimeType: 'text/markdown',
      paddedSize: vector.paddedSize,
    }))).toBe(vector.aadHex);
    const object = encodeVaultObject({
      fileId: vector.fileId,
      versionId: vector.versionId,
      nonce: sealed.nonce,
      ciphertext: sealed.ciphertext,
      authenticationTag: sealed.authenticationTag,
      paddedSize: sealed.paddedSize,
    });
    const decodedObject = decodeVaultObject(object);
    expect(decodedObject.fileId).toBe(vector.fileId);
    expect(decodedObject.versionId).toBe(vector.versionId);
    expect(decodedObject.paddedSize).toBe(vector.paddedSize);
    expect(hex(new Uint8Array(await crypto.subtle.digest(
      'SHA-256',
      object.slice().buffer as ArrayBuffer,
    ))))
      .toBe(vector.objectDigestHex);
    const encryptedPath = await sealVaultPath({
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      path: 'notes/语言.md',
      nonce: unhex(vector.pathNonceHex),
    });
    expect(hex(encryptedPath.ciphertext)).toBe(vector.pathCiphertextHex);
    expect(hex(encryptedPath.authenticationTag)).toBe(vector.pathAuthenticationTagHex);
    expect(await openVaultPath({
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      value: encryptedPath,
    })).toBe('notes/语言.md');
    const manifestRecord = {
      vaultId: '00000000-0000-0000-0000-000000000009',
      sequence: 1,
      entries: [{
        fileId: vector.fileId,
        currentVersionId: vector.versionId,
        encryptedPath,
        objectDigest: unhex(vector.objectDigestHex),
        byteSize: vector.plaintextSize,
        modifiedUnixMs: 1_700_000_000_000,
      }],
    };
    const manifest = encodeVaultManifest(manifestRecord);
    expect(hex(new Uint8Array(await crypto.subtle.digest(
      'SHA-256',
      manifest.slice().buffer as ArrayBuffer,
    ))))
      .toBe(vector.manifestCborSha256Hex);
    const signing = await crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify'],
    );
    const signedManifest = await signVaultManifest(
      manifestRecord,
      signing.privateKey,
      signing.publicKey,
    );
    const verifiedManifest = await decodeAndVerifySignedManifest(signedManifest);
    expect(verifiedManifest.manifest.vaultId).toBe(manifestRecord.vaultId);
    expect(verifiedManifest.manifest.entries[0].currentVersionId).toBe(vector.versionId);
    const opened = await openVaultObject({
      value: sealed,
      plaintextSize: vector.plaintextSize,
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
    });
    expect(new TextDecoder().decode(opened)).toBe(vector.plaintextUtf8);
  });

  it('rejects ciphertext mutation', async () => {
    const sealed = await sealVaultObject({
      plaintext: new TextEncoder().encode(vector.plaintextUtf8),
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
      nonce: unhex(vector.nonceHex),
    });
    sealed.ciphertext[0] ^= 1;
    await expect(openVaultObject({
      value: sealed,
      plaintextSize: vector.plaintextSize,
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
    })).rejects.toThrow();
  });

  it('round-trips binary attachments without UTF-8 conversion', async () => {
    const bytes = Uint8Array.from([0, 255, 1, 2, 3, 0, 128]);
    const sealed = await sealVaultObject({
      plaintext: bytes,
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
      kind: 'attachment',
      mimeType: 'application/octet-stream',
      nonce: unhex(vector.nonceHex),
    });
    const encoded = encodeVaultObject({
      ...sealed,
      fileId: vector.fileId,
      versionId: vector.versionId,
      kind: 'attachment',
      mimeType: 'application/octet-stream',
    });
    const object = decodeVaultObject(encoded);
    expect(object).toMatchObject({ kind: 'attachment', mimeType: 'application/octet-stream' });
    await expect(openVaultObject({
      value: object,
      plaintextSize: bytes.length,
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
      kind: object.kind,
      mimeType: object.mimeType,
    })).resolves.toEqual(bytes);
  });
});

describe('SignedDeviceGrantV1', () => {
  it('wraps the actual Vault key and verifies the authorizing device signature', async () => {
    const recipient = await crypto.subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' },
      true,
      ['deriveBits'],
    );
    const authorizer = await crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify'],
    );
    const recipientPublicKey = new Uint8Array(
      await crypto.subtle.exportKey('raw', recipient.publicKey),
    );
    const authorizerPublicKey = new Uint8Array(
      await crypto.subtle.exportKey('raw', authorizer.publicKey),
    );
    const grantId = '00000000-0000-0000-0000-000000000031';
    const masterKey = crypto.getRandomValues(new Uint8Array(32));
    const wrappedMasterKey = await hpkeSealP256({
      recipientPublicKey,
      plaintext: masterKey,
      aad: vaultUUIDBytes(grantId),
    });
    const signed = await signDeviceGrant({
      authorizerDeviceId: '00000000-0000-0000-0000-000000000032',
      signingKey: authorizer.privateKey,
      grant: {
        grantId,
        deviceId: '00000000-0000-0000-0000-000000000033',
        deviceHpkePublicKey: recipientPublicKey,
        deviceSigningPublicKey: authorizerPublicKey,
        permission: 'read_write',
        keyVersion: 1,
        createdUnixMs: 1_700_000_000_000,
        wrappedMasterKey,
      },
    });

    expect(decodeSignedDeviceGrant(signed).grant.deviceId)
      .toBe('00000000-0000-0000-0000-000000000033');
    const verified = await verifySignedDeviceGrant({
      value: signed,
      authorizerSigningPublicKey: authorizerPublicKey,
    });
    await expect(hpkeOpenP256({
      recipientPrivateKey: recipient.privateKey,
      recipientPublicKey,
      envelope: verified.grant.wrappedMasterKey,
      aad: vaultUUIDBytes(grantId),
    })).resolves.toEqual(masterKey);

    signed[signed.length - 1] ^= 1;
    await expect(verifySignedDeviceGrant({
      value: signed,
      authorizerSigningPublicKey: authorizerPublicKey,
    })).rejects.toThrow('Invalid device grant signature');
  });
});

describe('VaultObjectV1 large payloads', () => {
  it('seals and encodes a note larger than the call-argument limit', async () => {
    // Spreading the ciphertext into Array.prototype.push used to overflow the
    // stack around 128 KB, which made syncing any larger note impossible.
    const plaintext = new TextEncoder().encode('# Big note\n\n'.concat('lorem ipsum '.repeat(120_000)));
    expect(plaintext.length).toBeGreaterThan(1_000_000);
    const sealed = await sealVaultObject({
      plaintext,
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
    });
    const object = encodeVaultObject({
      fileId: vector.fileId,
      versionId: vector.versionId,
      nonce: sealed.nonce,
      ciphertext: sealed.ciphertext,
      authenticationTag: sealed.authenticationTag,
      paddedSize: sealed.paddedSize,
    });
    const decoded = decodeVaultObject(object);
    expect(decoded.ciphertext.length).toBe(sealed.ciphertext.length);
    expect(Buffer.from(decoded.ciphertext).equals(Buffer.from(sealed.ciphertext))).toBe(true);
    const opened = await openVaultObject({
      value: sealed,
      plaintextSize: plaintext.length,
      masterKey: unhex(vector.masterKeyHex),
      fileId: vector.fileId,
      versionId: vector.versionId,
    });
    expect(opened.length).toBe(plaintext.length);
  });
});
