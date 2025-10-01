#RUN CA EN AMONT :
#Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#puis :
#./setup.ps1

# Arrêter en cas d’erreur
$ErrorActionPreference = "Stop"

conda deactivate
conda env remove --name FinTech_RL
conda create --name FinTech_RL python=3.12
conda activate FinTech_RL

python.exe -m pip install --upgrade pip

Write-Host "Installation des dépendances Python..."

conda env update --file=environment.yml
pip install -r requirements.txt

Write-Host "Setup termine avec succes."


#attention on utilise un env conda linké au GPU sur WSL, pas celui ci au dessus
















makefile pour installer lenvironnement GPU sur WSL

make all VERBOSE=1

dans lautre treminal :
make watch-log

dans lautre:
watch -n 1 nvidia-smi


# Makefile — WSL2 + RTX 4060 (Ada, CC 8.9) + conda
# Suivi d'avancement : log continu, verbosité optionnelle, timing par étape.

# ========= Paramètres =========
ENV            ?= dl-gpu-2
CONDA          ?= conda
PYTHON         ?= python
PIP            ?= pip
TORCH_SCRIPT   ?= gpu_smoke_torch.py
TF_SCRIPT      ?= gpu_smoke_tf.py
LOG            ?= build.log
N              ?= auto           # Taille matrices; override: make test N=3072
VERBOSE        ?= 0              # 1 pour plus de logs
PIP_OPTS       ?=                # (évitez root; en dernier recours: --root-user-action=ignore)

# ========= Shell & options =========
SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# Verbosité conditionnelle
ifeq ($(VERBOSE),1)
  PIP_OPTS += -v
  CONDA_FLAGS = -v -v
  ECHO_PREFIX = "[VERBOSE]"
else
  CONDA_FLAGS =
  ECHO_PREFIX =
endif

# Raccourci conda run (sortie non capturée)
CRUN = $(CONDA) run --no-capture-output -n $(ENV)

# Commande de timing (portable)
TIME = time -p

# ========= Aide =========
.PHONY: help
help:
	@echo "Cibles :"
	@echo "  make all        -> env + TF + scripts + tests (torch+tf) avec log"
	@echo "  make env        -> crée l'env conda à partir de environment.yml"
	@echo "  make tf         -> installe tensorflow[and-cuda] dans l'env"
	@echo "  make scripts    -> écrit les scripts de smoke test"
	@echo "  make test       -> exécute torch-test et tf-test (N=$(N))"
	@echo "  make torch-test -> exécute seulement le test PyTorch (N=$(N))"
	@echo "  make tf-test    -> exécute seulement le test TensorFlow (N=$(N))"
	@echo "  make smi        -> affiche nvidia-smi (WSL)"
	@echo "  make watch-log  -> suit le log en direct (tail -f $(LOG))"
	@echo "  make clean      -> supprime les scripts"
	@echo "  make nuke       -> supprime l'env conda $(ENV)"
	@echo ""
	@echo "Options : VERBOSE=1 pour plus de logs ; N=3072 pour réduire la taille des tests."

# ========= Pipeline complet =========
.PHONY: all
all: reset-log environment.yml env tf scripts test
	@echo "[OK] Pipeline complet." | tee -a $(LOG)

# ========= Log utils =========
.PHONY: reset-log watch-log
reset-log:
	@echo "# Log démarré: $$(date -Is)" > $(LOG)
	@echo "" >> $(LOG)

watch-log:
	@echo "Suivi en temps réel du log (Ctrl+C pour quitter):"
	@tail -f $(LOG)

# ========= Fichiers =========
environment.yml:
	@echo "[$$(date +%T)] Génération de $@ $(ECHO_PREFIX)" | tee -a $(LOG)
	@{ \
	  printf "%s\n" \
"name: $(ENV)" \
"channels:" \
"  - pytorch" \
"  - nvidia" \
"  - conda-forge" \
"dependencies:" \
"  - python=3.12" \
"  - pytorch" \
"  - torchvision" \
"  - torchaudio" \
"  - pytorch-cuda=12.1" \
"  - pip" \
"  - pip:" \
"      - jupyterlab" \
	; } | tee -a $(LOG) > $@

$(TORCH_SCRIPT):
	@echo "[$$(date +%T)] Écriture $(TORCH_SCRIPT)" | tee -a $(LOG)
	@{ \
	  printf "%s\n" '#!/usr/bin/env python3' \
"import os, time, torch" \
'print(\"=== PyTorch smoke test ===\")' \
'print(\"Torch version:\", torch.__version__)' \
'print(\"CUDA available:\", torch.cuda.is_available())' \
'print(\"CUDA device count:\", torch.cuda.device_count())' \
'device = torch.device(\"cuda:0\" if torch.cuda.is_available() else \"cpu\")' \
'if device.type == \"cuda\": print(\"Device name:\", torch.cuda.get_device_name(0))' \
'N_env = os.environ.get(\"N\", \"auto\")' \
'if N_env == \"auto\": N = 4096 if device.type==\"cuda\" else 2048' \
'else: N = int(N_env)' \
'print(\"Using device:\", device, \"| N =\", N)' \
'a = torch.randn((N, N), device=device)' \
'b = torch.randn((N, N), device=device)' \
'if device.type == \"cuda\": torch.cuda.synchronize()' \
't0 = time.time()' \
'c = a @ b' \
'if device.type == \"cuda\": torch.cuda.synchronize()' \
'dt = time.time() - t0' \
'print(f\"Matmul {N}x{N} done in {dt:.3f}s on {device}\")' \
'if device.type == \"cuda\":' \
'    alloc = torch.cuda.memory_allocated() / (1024**2)' \
'    reserved = torch.cuda.memory_reserved() / (1024**2)' \
'    print(f\"CUDA memory - allocated: {alloc:.1f} MiB, reserved: {reserved:.1f} MiB\")' \
'print(\"OK.\")' \
	; } > $(TORCH_SCRIPT)
	@chmod +x $(TORCH_SCRIPT)

$(TF_SCRIPT):
	@echo "[$$(date +%T)] Écriture $(TF_SCRIPT)" | tee -a $(LOG)
	@{ \
	  printf "%s\n" '#!/usr/bin/env python3' \
"import os, time, tensorflow as tf" \
'print(\"=== TensorFlow smoke test ===\")' \
'print(\"TF version:\", tf.__version__)' \
'gpus = tf.config.list_physical_devices(\"GPU\")' \
'print(\"Physical GPUs:\", gpus)' \
'for g in gpus:' \
'    try: tf.config.experimental.set_memory_growth(g, True)' \
'    except Exception as e: print(\"set_memory_growth failed:\", e)' \
'target = \"/GPU:0\" if gpus else \"/CPU:0\"' \
'N_env = os.environ.get(\"N\", \"auto\")' \
'if N_env == \"auto\": N = 4096 if gpus else 2048' \
'else: N = int(N_env)' \
'print(\"Using device:\", target, \"| N =\", N)' \
'with tf.device(target):' \
'    a = tf.random.normal([N, N])' \
'    b = tf.random.normal([N, N])' \
'    @tf.function(jit_compile=False)' \
'    def matmul_op(x, y): return tf.matmul(x, y)' \
'_ = matmul_op(a, b)' \
't0 = time.time()' \
'c = matmul_op(a, b)' \
'_ = c.numpy()' \
'dt = time.time() - t0' \
'print(f\"Matmul {N}x{N} done in {dt:.3f}s on:\", c.device)' \
'print(\"OK.\")' \
	; } > $(TF_SCRIPT)
	@chmod +x $(TF_SCRIPT)

# Regroupe la génération des deux scripts
.PHONY: scripts
scripts: $(TORCH_SCRIPT) $(TF_SCRIPT)
	@echo "[$$(date +%T)] Scripts générés." | tee -a $(LOG)

# ========= Environnement conda =========
.PHONY: env
env: environment.yml
	@echo "[$$(date +%T)] Création/validation de l'environnement $(ENV)" | tee -a $(LOG)
	@{ \
	  if ! $(CONDA) env list | grep -E '^$(ENV)[[:space:]]' >/dev/null; then \
	    echo "[STEP] conda env create -f environment.yml $(CONDA_FLAGS)"; \
	    $(TIME) $(CONDA) env create -f environment.yml $(CONDA_FLAGS); \
	  else \
	    echo "[INFO] L'environnement $(ENV) existe déjà."; \
	  fi \
	; } 2>&1 | tee -a $(LOG)
	@echo "[$$(date +%T)] env: OK." | tee -a $(LOG)

# ========= TensorFlow via pip dans l'env =========
.PHONY: tf
tf:
	@echo "[$$(date +%T)] Installation TensorFlow [and-cuda] dans $(ENV)" | tee -a $(LOG)
	@{ \
	  echo "[STEP] pip upgrade"; \
	  $(TIME) $(CRUN) $(PYTHON) -m pip install --upgrade pip $(PIP_OPTS); \
	  echo "[STEP] pip install tensorflow[and-cuda]"; \
	  $(TIME) $(CRUN) $(PYTHON) -m pip install "tensorflow[and-cuda]" $(PIP_OPTS); \
	; } 2>&1 | tee -a $(LOG)
	@echo "[$$(date +%T)] tf: OK." | tee -a $(LOG)

# ========= Tests =========
.PHONY: torch-test
torch-test: $(TORCH_SCRIPT)
	@echo "[$$(date +%T)] >>> Test PyTorch (N=$(N))" | tee -a $(LOG)
	@N=$(N) $(TIME) $(CRUN) $(PYTHON) $(TORCH_SCRIPT) 2>&1 | tee -a $(LOG)

.PHONY: tf-test
tf-test: $(TF_SCRIPT)
	@echo "[$$(date +%T)] >>> Test TensorFlow (N=$(N))" | tee -a $(LOG)
	@N=$(N) $(TIME) $(CRUN) $(PYTHON) $(TF_SCRIPT) 2>&1 | tee -a $(LOG)

.PHONY: test
test: torch-test tf-test
	@echo "[$$(date +%T)] test: OK." | tee -a $(LOG)

# ========= Utilitaires =========
.PHONY: smi
smi:
	@echo "[$$(date +%T)] nvidia-smi (WSL):" | tee -a $(LOG)
	@{ nvidia-smi || (echo "⚠️  nvidia-smi indisponible. Vérifiez WSL2 + pilote Windows." && false); } 2>&1 | tee -a $(LOG)

.PHONY: clean
clean:
	@rm -f $(TORCH_SCRIPT) $(TF_SCRIPT)
	@echo "[$$(date +%T)] Scripts supprimés." | tee -a $(LOG)

.PHONY: nuke
nuke:
	@echo "[$$(date +%T)] Suppression de l'environnement conda $(ENV)" | tee -a $(LOG)
	@$(CONDA) env remove -n $(ENV) -y || true
	@echo "[$$(date +%T)] nuke: OK." | tee -a $(LOG)
