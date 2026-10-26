"""Tiny generated test dictionaries, not bundled language resources."""
from pathlib import Path
import struct


def create_dictionary(directory):
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    entries = {"hello": "喂；你好", "学习": "learn; study", "bank": "银行；河岸"}
    data = bytearray()
    index = bytearray()
    for word in sorted(entries, key=lambda value: value.encode("utf-8")):
        definition = entries[word].encode("utf-8")
        index.extend(word.encode("utf-8") + b"\0" + struct.pack(">II", len(data), len(definition)))
        data.extend(definition)
    (root / "test.dict").write_bytes(data)
    (root / "test.idx").write_bytes(index)
    (root / "test.ifo").write_text(
        "StarDict's dict ifo file\nversion=2.4.2\nbookname=CrossLang test fixture\n"
        f"wordcount={len(entries)}\nidxfilesize={len(index)}\nsametypesequence=m\n", encoding="utf-8")
    return str(root)
