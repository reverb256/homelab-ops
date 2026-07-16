package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/cosmos/cosmos-sdk/types"
	"golang.org/x/crypto/ripemd160"
)

func main() {
	privateKeyHex := "63836ebc5d3eeb88ba2105daf61190640b17fb5943fab1da280ff0bcbcc43e62"
	
	privKeyBytes, err := hex.DecodeString(privateKeyHex)
	if err != nil {
		log.Fatal(err)
	}
	
	privKey, _ := btcec.PrivKeyFromBytes(privKeyBytes)
	pubKey := privKey.PubKey()
	pubKeyUncompressed := pubKey.SerializeUncompressed()
	pubKeyBytes := pubKeyUncompressed[1:]
	
	pubKeyBase64 := base64.StdEncoding.EncodeToString(pubKeyBytes)
	
	hasher := sha256.New()
	hasher.Write(pubKeyBytes)
	hash := hasher.Sum(nil)
	
	ripe := ripemd160.New()
	ripe.Write(hash)
	ripeHash := ripe.Sum(nil)
	
	address := types.MustBech32ifyAddressBytes("akash", ripeHash)
	
	fmt.Printf("Public Key (base64): %s\n", pubKeyBase64)
	fmt.Printf("Address: %s\n", address)
}
