import CryptoKit
import Foundation

let privateKey = Curve25519.Signing.PrivateKey()
let privateKeyBase64 = privateKey.rawRepresentation.base64EncodedString()
let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

print("CLAIR_UPDATE_PRIVATE_KEY=\(privateKeyBase64)")
print("CLAIR_UPDATE_PUBLIC_KEY=\(publicKeyBase64)")
FileHandle.standardError.write(
  Data(
    "Store the private value in GitHub Actions secrets and the public value in repository variables.\n"
      .utf8
  )
)
