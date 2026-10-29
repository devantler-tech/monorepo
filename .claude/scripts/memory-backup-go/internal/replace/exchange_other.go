//go:build !linux && !darwin

package replace

import "errors"

func exchangeNative(int, string, int, string) error {
	return errors.New("atomic file exchange is unsupported on this operating system")
}
