package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"

	"filippo.io/age"
)

const (
	maximumPassphraseBytes = 4096
	minimumPassphraseBytes = 1
	minimumNewPassphrase   = 12
	maximumWorkFactor      = 20
	statusPrefix           = "MACEASE_AGE_ERROR:"
)

var (
	authenticationFailure = errors.New("age authentication failed")
	verificationFailure   = errors.New("age verification failed")
)

type failureCategory string

const (
	failureAuthentication failureCategory = "authentication"
	failureDiskFull       failureCategory = "disk-full"
	failurePermission     failureCategory = "permission"
	failureIntegrity      failureCategory = "integrity"
	failureIO             failureCategory = "io"
)

func main() {
	if err := run(os.Args[1:], os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, statusPrefix+string(categoryFor(err)))
		os.Exit(1)
	}
}

func categoryFor(err error) failureCategory {
	if errors.Is(err, syscall.ENOSPC) || errors.Is(err, syscall.EDQUOT) {
		return failureDiskFull
	}
	if errors.Is(err, os.ErrPermission) || errors.Is(err, syscall.EPERM) {
		return failurePermission
	}
	var pathError *os.PathError
	if errors.As(err, &pathError) {
		return failureIO
	}
	if errors.Is(err, authenticationFailure) {
		return failureAuthentication
	}
	if errors.Is(err, verificationFailure) {
		return failureIntegrity
	}
	return failureIO
}

func run(args []string, secret io.Reader) (runErr error) {
	if len(args) != 3 || (args[0] != "encrypt" && args[0] != "decrypt" && args[0] != "verify") {
		return errors.New("invalid operation")
	}
	password, err := readPassphrase(secret)
	if err != nil {
		return err
	}
	defer clear(password)
	if args[0] == "encrypt" && len(password) < minimumNewPassphrase {
		return errors.New("passphrase too short")
	}
	source, err := openRegular(args[1])
	if err != nil {
		return err
	}
	defer func() { runErr = errors.Join(runErr, source.Close()) }()
	if args[0] == "verify" {
		return verify(source, args[2], string(password))
	}
	output, err := os.OpenFile(args[2], os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	complete := false
	closed := false
	defer func() {
		if !closed {
			runErr = errors.Join(runErr, output.Close())
		}
		if !complete {
			if removeErr := os.Remove(args[2]); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
				runErr = errors.Join(runErr, removeErr)
			}
		}
	}()
	if args[0] == "encrypt" {
		recipient, err := age.NewScryptRecipient(string(password))
		if err != nil {
			return err
		}
		writer, err := age.Encrypt(output, recipient)
		if err != nil {
			return err
		}
		if _, err = io.Copy(writer, source); err != nil {
			return err
		}
		if err = writer.Close(); err != nil {
			return err
		}
	} else {
		reader, err := decrypt(source, string(password))
		if err != nil {
			return fmt.Errorf("%w: %w", authenticationFailure, err)
		}
		if _, err = io.Copy(output, reader); err != nil {
			return fmt.Errorf("%w: %w", authenticationFailure, err)
		}
	}
	if err = output.Sync(); err != nil {
		return err
	}
	closeErr := output.Close()
	closed = true
	if closeErr != nil {
		return closeErr
	}
	complete = true
	return nil
}

func readPassphrase(reader io.Reader) ([]byte, error) {
	var length [4]byte
	if _, err := io.ReadFull(reader, length[:]); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(length[:])
	if size < minimumPassphraseBytes || size > maximumPassphraseBytes {
		return nil, errors.New("invalid passphrase length")
	}
	password := make([]byte, size)
	if _, err := io.ReadFull(reader, password); err != nil {
		clear(password)
		return nil, err
	}
	var trailing [1]byte
	if count, err := io.ReadFull(reader, trailing[:]); count != 0 || err != io.EOF {
		clear(password)
		return nil, errors.New("invalid passphrase frame")
	}
	return password, nil
}

func openRegular(path string) (*os.File, error) {
	descriptor, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(descriptor), path)
	metadata, err := file.Stat()
	if err != nil || !metadata.Mode().IsRegular() {
		closeErr := file.Close()
		if err != nil {
			return nil, errors.Join(err, closeErr)
		}
		return nil, errors.Join(errors.New("source is not a regular file"), closeErr)
	}
	return file, nil
}

func decrypt(source io.Reader, password string) (io.Reader, error) {
	identity, err := age.NewScryptIdentity(password)
	if err != nil {
		return nil, err
	}
	identity.SetMaxWorkFactor(maximumWorkFactor)
	return age.Decrypt(source, identity)
}

func verify(source io.Reader, originalPath, password string) (verificationErr error) {
	reader, err := decrypt(source, password)
	if err != nil {
		return fmt.Errorf("%w: %w", authenticationFailure, err)
	}
	decryptedHash := sha256.New()
	decryptedBytes, err := io.Copy(decryptedHash, reader)
	if err != nil {
		return fmt.Errorf("%w: %w", authenticationFailure, err)
	}
	original, err := openRegular(originalPath)
	if err != nil {
		return err
	}
	defer func() { verificationErr = errors.Join(verificationErr, original.Close()) }()
	originalHash := sha256.New()
	originalBytes, err := io.Copy(originalHash, original)
	if err != nil {
		return err
	}
	if decryptedBytes != originalBytes || subtle.ConstantTimeCompare(decryptedHash.Sum(nil), originalHash.Sum(nil)) != 1 {
		return verificationFailure
	}
	return nil
}

func clear(bytes []byte) {
	for index := range bytes {
		bytes[index] = 0
	}
}
