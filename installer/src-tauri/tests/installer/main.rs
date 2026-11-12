//! The installer's tests, against a fake iPhone, Apple, anisette server and
//! GitHub (README.md): what the window does, from listing the iPhone to
//! Cartouche installed with its pairing file, and everything that can go
//! wrong on the way.

mod harness;

mod download;
mod install;
mod keychain;
mod own_certificate;
mod pairing;
mod sign_in;
