#!/usr/bin/env python

# This is a simple demonstration client for the "0install slave" JSON API.
# This file is in the Public Domain.

import subprocess, json
import logging, sys

# 0 = low
# 1 = show our messages
# 2 = enabled logging in slave
verbosity = 0

if verbosity > 0:
	logging.getLogger("").setLevel(logging.INFO)

if len(sys.argv) == 2:
	iface, = sys.argv[1:]
else:
	print("Usage: %s IFACE" % sys.argv[0])
	sys.exit(1)

slave_args = ["./0install", "--console", "slave"]
if verbosity > 1: slave_args.append("-v")

c = subprocess.Popen(slave_args, stdin = subprocess.PIPE, stdout = subprocess.PIPE)

next_ticket = 1

callbacks = {}

def get_chunk():
	len_line = c.stdout.readline()
	assert len_line.startswith(b"0x")
	assert len_line.endswith(b"\n")
	chunk_len = int(len_line[2:-1], 16)
	#print("chunk length = %d" % chunk_len)
	data = json.loads(c.stdout.read(chunk_len).decode('utf-8'))
	logging.info("From slave: %s", data)
	#print("got", data)
	return data

def send_chunk(value):
	data = json.dumps(value)
	logging.info("To slave: %s", data)
	c.stdin.write((('0x%08x\n' % len(data)) + data).encode('utf-8'))
	c.stdin.flush()

def invoke(on_success, op, *args):
	global next_ticket
	ticket = str(next_ticket)
	next_ticket += 1
	callbacks[ticket] = on_success
	send_chunk(["invoke", ticket, op, args])
	return ticket

def reply_ok(ticket, response):
	send_chunk(["return", ticket, "ok", response])

def reply_fail(ticket, response):
	send_chunk(["return", ticket, "fail", response])

def do_select_api_version(proposed_by_server):
	logging.info("Server can support up to version %s", proposed_by_server)
	return "2.5"

def do_confirm_keys(feed, keys):
	print("Feed:", feed)
	print("The feed is correctly signed with the following keys:")
	for key, hints in keys.items():
		print("- " + key)
		for vote, msg in hints:
			print("   ", vote.upper(), msg)
	while True:
		r = input("Trust these keys? [YN]")
		if r in 'Yy': return list(keys)
		if r in 'Nn': return []

handlers = {
	"select-api-version": do_select_api_version,
	"confirm-keys": do_confirm_keys,
	"update-key-info": lambda *unused: None,
}

def handle_next_chunk():
	api_request = get_chunk()
	if api_request[0] == "invoke":
		ticket = api_request[1]
		op = api_request[2]
		args = api_request[3]
		try:
			response = handlers[op](*args)
			reply_ok(ticket, response)
		except Exception as ex:
			logging.warning("Operation %s(%s) failed", op, ', '.join(args), exc_info = True)
			reply_fail(ticket, str(ex))
	elif api_request[0] == "return":
		ticket = api_request[1]
		cb = callbacks.pop(ticket)
		if api_request[2] == 'ok': cb(*api_request[3])
		else:
			assert api_request[2] == 'fail', api_request
			raise Exception(api_request[3])
	else:
		assert 0, api_request

handle_next_chunk()		# Agree API version

requirements = {
	"interface": iface,
}

def show_selections(status, result):
	print(status)
	print(result)
	sys.exit(0)

refresh = False
ticket = invoke(show_selections, "select", requirements, refresh)

while True:
	handle_next_chunk()
