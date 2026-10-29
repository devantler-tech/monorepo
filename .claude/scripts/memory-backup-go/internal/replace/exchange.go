package replace

import (
	"os"
	"path/filepath"
)

// Bind both parent directories before the native call. An unsupported kernel or
// filesystem must refuse: ordinary rename cannot preserve a displaced inode.
func exchangeFiles(first, second string) error {
	a, err := os.Open(filepath.Dir(first))
	if err != nil {
		return err
	}
	defer a.Close()
	b, err := os.Open(filepath.Dir(second))
	if err != nil {
		return err
	}
	defer b.Close()
	return exchangeNative(int(a.Fd()), filepath.Base(first), int(b.Fd()), filepath.Base(second))
}
