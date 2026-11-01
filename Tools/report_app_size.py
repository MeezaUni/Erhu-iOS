"""Report the built IPA and compiled model size in the CI run's public summary."""
import os
import sys
from pathlib import Path

app, ipa = map(Path, sys.argv[1:3])
model = app / "VybeSentence.mlmodelc"
model_bytes = sum(p.stat().st_size for p in model.rglob("*") if p.is_file())
ipa_bytes = ipa.stat().st_size
message = f"IPA {ipa_bytes / 1_000_000:.2f} MB; compiled VYBE model {model_bytes / 1_000_000:.2f} MB"
print("::notice title=App size::" + message)
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
    summary.write("## App size\n\n" + message + ".\n")

