package replace

import "golang.org/x/sys/unix"

func exchangeNative(firstFD int, first string, secondFD int, second string) error {
	return unix.RenameatxNp(firstFD, first, secondFD, second, unix.RENAME_SWAP)
}
