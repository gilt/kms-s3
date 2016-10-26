TARGET=target
EXE=$(TARGET)/kms-s3
DIST_EXE=$(EXE)-$(shell uname -s)-$(shell uname -m)
DIST_EXE_SIG=$(DIST_EXE).gpg.sig

build:
	stack build kms-s3

build-prof:
	stack build --profile --ghc-options="-rtsopts" kms-s3

install:
	stack install kms-s3

bindist:
	mkdir -p $(TARGET)
	stack --local-bin-path $(TARGET) install kms-s3
	upx --best $(EXE)
	mv $(EXE) $(DIST_EXE)
	gpg --output $(DIST_EXE_SIG) --detach-sign $(DIST_EXE)

clean:
	stack clean
	rm -rf target

tags:
	hasktags-generate .

sources:
	stack-unpack-dependencies


.PHONY: build build-prof clean tags sources
