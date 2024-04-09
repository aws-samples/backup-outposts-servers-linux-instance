TARGET_DIR = "./Output"
PYTHON3:=$(shell command -v python3 --version 2> /dev/null)
DOCUMENT_NAME = "BackupOutpostsServerLinuxInstanceToEBS.json"

ifdef PYTHON3
	PYTHON:=python3
else:
	$(error "Did not find required python3 or python2 executable!")
	exit 1
endif

documents: clean
	@if [ ! -d ./Output/ ] ; then					\
		echo "Making $(TARGET_DIR)";				\
		mkdir -p ./Output;							\
	fi
	$(PYTHON) ./Setup/create_document.py --document_name $(DOCUMENT_NAME) > ./Output/$(DOCUMENT_NAME)
	@echo "Done making documents"
	
clean:
	@echo "Removing $(TARGET_DIR)"
	@rm -rf ./Output
