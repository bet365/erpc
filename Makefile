PROJECT = erpc
PLT_APPS=ssl crypto public_key
include erlang.mk

test: stop_test_nodes start_test_nodes ct stop_test_nodes

start_test_nodes:
	@echo "Starting test node 1..."
	@erl -pa ebin -pz test -sname erpc_test_1@localhost -config test/erpc_test_1_sys -s erpc_app start -detached
	@echo "Starting test node 2..."
	@erl -pa ebin -pz test -sname erpc_test_2@localhost -config test/erpc_test_2_sys -s erpc_app start -detached

stop_test_nodes:
	@echo "Stopping any existing test nodes..."
	@erl -sname erpc_test_node_killer -noinput +B \
	-eval 'rpc:async_call(erpc_test_1@localhost, erlang, halt, []), rpc:async_call(erpc_test_2@localhost, erlang, halt, []), timer:sleep(1000), erlang:halt().'

LOAD_TEST_NUM_WORKERS=20000
LOAD_TEST_NUM_REQS_PER_WORKER=100

erpc_load_test: stop_test_nodes start_test_nodes erpc_load_test_run stop_test_nodes

erpc_load_test_run:
	@cd test && erlc run_load_test.erl && cd ..
	erl -sname erpc_test_client -pa ebin -pz test -s run_load_test start -- \
	-num_workers ${LOAD_TEST_NUM_WORKERS} \
	-num_requests_per_worker ${LOAD_TEST_NUM_REQS_PER_WORKER} \
	-num_connections_per_node 1 \
	-num_erpc_server_nodes 1 \
	-rpc_type erpc

rpc_load_test: stop_test_nodes start_test_nodes rpc_load_test_run stop_test_nodes

rpc_load_test_run:
	@cd test && erlc run_load_test.erl && cd ..
	@erl -sname rpc_test_client -pa ebin -pz test -s run_load_test start -- \
	-num_workers ${LOAD_TEST_NUM_WORKERS} \
	-num_requests_per_worker ${LOAD_TEST_NUM_REQS_PER_WORKER} \
	-rpc_type native
