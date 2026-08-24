use k256::ecdsa::{hazmat, Signature, SigningKey};
use k256::elliptic_curve::{bigint::U256, ops::Reduce, PrimeField};
use k256::{FieldBytes, Scalar, Secp256k1};
use sha2::Sha256;
use std::{env, fs};

const ORDER: [u8; 32] = hex_literal_order();

const fn hex_literal_order() -> [u8; 32] {
    [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
        0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41,
    ]
}

fn decode_32(text: &str) -> [u8; 32] {
    let bytes = hex::decode(text).expect("lower-case hex input");
    bytes.try_into().expect("32-byte input")
}

fn emit(kind: &str, id: usize, key: &[u8; 32], digest: &[u8; 32], message: Option<&str>) {
    let signing_key = SigningKey::from_slice(key).expect("valid private scalar");
    let z = FieldBytes::from(*digest);
    let z_reduced = <Scalar as Reduce<U256>>::reduce_bytes(&z).to_repr();
    let k_bytes = rfc6979::generate_k::<Sha256, _>(
        &FieldBytes::from(*key),
        &FieldBytes::from(ORDER),
        &z_reduced,
        &[],
    );
    let k = Option::<Scalar>::from(Scalar::from_repr(k_bytes)).expect("valid RFC6979 scalar");
    let (raw, _) = hazmat::sign_prehashed::<Secp256k1, Scalar>(
        signing_key.as_nonzero_scalar().as_ref(),
        k,
        &z,
    )
    .expect("raw ECDSA signature");
    let low: Signature = raw.normalize_s().unwrap_or(raw);
    let raw_bytes = raw.to_bytes();
    let low_bytes = low.to_bytes();
    let public = signing_key.verifying_key().to_encoded_point(true);

    print!("{kind} {id} {}", hex::encode(key));
    if let Some(message) = message {
        print!(" {message}");
    }
    println!(
        " {} {} {} {} {} {} {}",
        hex::encode(digest),
        hex::encode(public.as_bytes()),
        hex::encode(k.to_repr()),
        hex::encode(&raw_bytes[..32]),
        hex::encode(&raw_bytes[32..]),
        hex::encode(&low_bytes[32..]),
        hex::encode(low_bytes),
    );
}

fn main() {
    let path = env::args().nth(1).expect("signing input manifest path");
    let text = fs::read_to_string(path).expect("read signing input manifest");
    let mut keys = [[0u8; 32]; 16];
    let mut digests = [[0u8; 32]; 16];

    for line in text.lines().filter(|line| !line.is_empty() && !line.starts_with('#')) {
        let fields: Vec<_> = line.split_whitespace().collect();
        match fields[0] {
            "key" => keys[fields[1].parse::<usize>().unwrap()] = decode_32(fields[2]),
            "digest" => digests[fields[1].parse::<usize>().unwrap()] = decode_32(fields[2]),
            _ => {}
        }
    }
    for line in text.lines().filter(|line| !line.is_empty() && !line.starts_with('#')) {
        let fields: Vec<_> = line.split_whitespace().collect();
        match fields[0] {
            "pair" => emit(
                "sign",
                fields[1].parse().unwrap(),
                &keys[fields[2].parse::<usize>().unwrap()],
                &digests[fields[3].parse::<usize>().unwrap()],
                None,
            ),
            "pds" => emit(
                "pds-ref",
                fields[1].parse().unwrap(),
                &keys[fields[2].parse::<usize>().unwrap()],
                &decode_32(fields[4]),
                Some(fields[3]),
            ),
            _ => {}
        }
    }
}
