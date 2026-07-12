//go:build linux

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	flag.Usage = func() {
		fmt.Fprintln(flag.CommandLine.Output(), "Usage: ocserv-control [serve|healthcheck]")
	}
	flag.Parse()
	command := "serve"
	if flag.NArg() > 1 {
		flag.Usage()
		os.Exit(2)
	}
	if flag.NArg() == 1 {
		command = flag.Arg(0)
	}
	if command != "serve" && command != "healthcheck" {
		flag.Usage()
		os.Exit(2)
	}
	cfg, err := configFromEnvironment()
	if err != nil {
		log.Fatal(err)
	}
	if command == "healthcheck" {
		if err = healthcheck(cfg); err != nil {
			log.Print(err)
			os.Exit(1)
		}
		return
	}
	service := newControlService(cfg, nil)
	server, err := newControlServer(cfg, service)
	if err != nil {
		log.Fatal(err)
	}
	defer server.close()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	log.Printf("control socket is ready at %s", cfg.SocketPath)
	if err = server.serve(ctx); err != nil {
		log.Fatal(err)
	}
}
