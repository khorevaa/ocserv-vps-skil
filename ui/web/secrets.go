package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"syscall"
)

func readManagedSecret(path, label string, requireRoot bool) ([]byte, error) {
	linkInfo, err := os.Lstat(path)
	if err != nil || linkInfo.Mode()&os.ModeSymlink != 0 || !linkInfo.Mode().IsRegular() {
		return nil, fmt.Errorf("required %s secret is missing or unsafe", label)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot open %s secret", label)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !os.SameFile(linkInfo, info) || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s secret changed during validation", label)
	}
	if requireRoot {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 || stat.Gid != uint32(os.Getegid()) || info.Mode().Perm()&0o037 != 0 {
			return nil, fmt.Errorf("%s secret has unsafe ownership or permissions", label)
		}
	} else if info.Mode().Perm()&0o022 != 0 {
		return nil, fmt.Errorf("%s secret is writable by group or others", label)
	}
	data, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil {
		return nil, fmt.Errorf("cannot read %s secret", label)
	}
	if len(data) > 4096 {
		return nil, fmt.Errorf("%s secret is too large", label)
	}
	data = bytes.TrimRight(data, "\r\n")
	if len(data) == 0 || bytes.IndexByte(data, 0) >= 0 {
		return nil, fmt.Errorf("%s secret is empty or invalid", label)
	}
	return data, nil
}
