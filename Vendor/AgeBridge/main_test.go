package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"filippo.io/age"
)

const testPassword = "correct horse battery staple"

func frame(password string) io.Reader {
	var buffer bytes.Buffer
	var size [4]byte
	binary.BigEndian.PutUint32(size[:], uint32(len(password)))
	buffer.Write(size[:])
	buffer.WriteString(password)
	return &buffer
}

func TestBridgeInteroperatesWithAge(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.txt")
	encrypted := filepath.Join(root, "source.txt.age")
	decrypted := filepath.Join(root, "decrypted.txt")
	payload := bytes.Repeat([]byte("interoperable age payload\n"), 1000)
	if err := os.WriteFile(source, payload, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"encrypt", source, encrypted}, frame(testPassword)); err != nil {
		t.Fatal(err)
	}
	metadata, err := os.Stat(encrypted)
	if err != nil || metadata.Mode().Perm()&0077 != 0 {
		t.Fatalf("ciphertext staging permissions are not private: %v", err)
	}
	if err := run([]string{"verify", encrypted, source}, frame(testPassword)); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(encrypted)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := decrypt(file, testPassword)
	if err != nil {
		t.Fatal(err)
	}
	standardOutput, err := io.ReadAll(reader)
	closeErr := file.Close()
	if err != nil || !bytes.Equal(standardOutput, payload) {
		t.Fatalf("standard age API could not read bridge output: %v", err)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}
	standardFile := filepath.Join(root, "standard.age")
	var standard bytes.Buffer
	recipient, err := age.NewScryptRecipient(testPassword)
	if err != nil {
		t.Fatal(err)
	}
	writer, err := age.Encrypt(&standard, recipient)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(standardFile, standard.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"decrypt", standardFile, decrypted}, frame(testPassword)); err != nil {
		t.Fatal(err)
	}
	result, err := os.ReadFile(decrypted)
	if err != nil || !bytes.Equal(result, payload) {
		t.Fatalf("bridge could not read standard age output: %v", err)
	}
	shortRecipient, err := age.NewScryptRecipient("short")
	if err != nil {
		t.Fatal(err)
	}
	var shortCipher bytes.Buffer
	shortWriter, err := age.Encrypt(&shortCipher, shortRecipient)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := shortWriter.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := shortWriter.Close(); err != nil {
		t.Fatal(err)
	}
	shortFile := filepath.Join(root, "short.age")
	if err := os.WriteFile(shortFile, shortCipher.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	shortOutput := filepath.Join(root, "short-output")
	if err := run([]string{"decrypt", shortFile, shortOutput}, frame("short")); err != nil {
		t.Fatal(err)
	}
	shortResult, err := os.ReadFile(shortOutput)
	if err != nil || !bytes.Equal(shortResult, payload) {
		t.Fatalf("bridge could not read standard age output with a short passphrase: %v", err)
	}
}

func TestFailuresLeaveNoPlaintext(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source")
	encrypted := filepath.Join(root, "encrypted.age")
	if err := os.WriteFile(source, bytes.Repeat([]byte("secret"), 100), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"encrypt", source, encrypted}, frame(testPassword)); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(encrypted)
	if err != nil {
		t.Fatal(err)
	}
	for name, encryptedBytes := range map[string][]byte{
		"wrong password": data,
		"tampered":       append(append([]byte(nil), data[:len(data)-1]...), data[len(data)-1]^0x80),
		"truncated":      data[:len(data)-1],
	} {
		t.Run(name, func(t *testing.T) {
			input := filepath.Join(root, name+".age")
			output := filepath.Join(root, name+".txt")
			if err := os.WriteFile(input, encryptedBytes, 0600); err != nil {
				t.Fatal(err)
			}
			password := testPassword
			if name == "wrong password" {
				password = "different password"
			}
			if err := run([]string{"decrypt", input, output}, frame(password)); categoryFor(err) != failureAuthentication {
				t.Fatalf("expected authentication failure, got %v", err)
			}
			if _, err := os.Stat(output); !os.IsNotExist(err) {
				t.Fatalf("plaintext output remained: %v", err)
			}
		})
	}
}

func TestFailureCategoriesKeepFilesystemErrorsDistinct(t *testing.T) {
	for _, candidate := range []struct {
		err      error
		expected failureCategory
	}{
		{&os.PathError{Op: "write", Path: "output", Err: syscall.ENOSPC}, failureDiskFull},
		{&os.PathError{Op: "open", Path: "input", Err: syscall.EACCES}, failurePermission},
		{verificationFailure, failureIntegrity},
		{&os.PathError{Op: "read", Path: "input", Err: syscall.EIO}, failureIO},
	} {
		if actual := categoryFor(candidate.err); actual != candidate.expected {
			t.Fatalf("expected %s, got %s", candidate.expected, actual)
		}
	}
}

func TestPassphraseFrameIsBounded(t *testing.T) {
	for _, size := range []uint32{0, 4097, ^uint32(0)} {
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], size)
		if _, err := readPassphrase(bytes.NewReader(length[:])); err == nil {
			t.Fatalf("accepted invalid length %d", size)
		}
	}
	var extra bytes.Buffer
	length := [4]byte{0, 0, 0, 12}
	extra.Write(length[:])
	extra.WriteString("twelve bytes")
	extra.WriteByte('x')
	if _, err := readPassphrase(&extra); err == nil {
		t.Fatal("accepted trailing passphrase bytes")
	}
}

func TestDecryptRejectsExcessiveScryptWorkBeforeDerivation(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source")
	encrypted := filepath.Join(root, "encrypted.age")
	if err := os.WriteFile(source, []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"encrypt", source, encrypted}, frame(testPassword)); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(encrypted)
	if err != nil {
		t.Fatal(err)
	}
	forged := bytes.Replace(data, []byte(" 18\n"), []byte(" 21\n"), 1)
	if bytes.Equal(forged, data) {
		t.Fatal("expected scrypt header")
	}
	if err := os.WriteFile(encrypted, forged, 0600); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(root, "output")
	err = run([]string{"decrypt", encrypted, output}, frame(testPassword))
	if err == nil || !strings.Contains(err.Error(), "work factor") {
		t.Fatalf("expected work factor rejection, got %v", err)
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("plaintext output remained: %v", err)
	}
}
