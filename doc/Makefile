SOURCES=erpc_lb_conn.dot erpc_p2p.dot

PNGS=$(SOURCES:.dot=.png)

all: $(PNGS)

%.png: %.dot
	dot -Tpng -o $@ $<
