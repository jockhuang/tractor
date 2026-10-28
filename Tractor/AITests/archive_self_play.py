#!/usr/bin/env python3
"""保存审计牌局和种子配置；只省略可从初始牌及逐手记录还原的重复手牌。"""
import argparse
import hashlib
import json
from pathlib import Path


def archive(source: Path, batch_id: str, label: str, current_engine: bool) -> None:
    root = Path(__file__).resolve().parents[1]
    destination = root / "AITests" / "SelfPlay"
    destination.mkdir(exist_ok=True)
    index_path = destination / "seeds.json"
    index = json.loads(index_path.read_text()) if index_path.exists() else {"formatVersion": 1, "batches": []}
    if not batch_id or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in batch_id):
        raise ValueError("批次ID只能包含小写字母、数字和短横线")
    if any(batch["id"] == batch_id for batch in index["batches"]):
        raise ValueError("批次已存在；请使用新ID，保留旧策略的实际记录")
    rounds = json.loads(source.read_text())
    configurations = []
    for round_ in rounds:
        cards = sum(round_["initialHands"], []) + round_["kitty"]
        assert len(round_["initialHands"]) == 4 and all(len(h) == 25 for h in round_["initialHands"])
        assert len(round_["kitty"]) == 8 and len({c["id"] for c in cards}) == 108
        assert round_["legal"] and sum(len(d["played"]) for d in round_["decisions"]) == 100
        for decision in round_["decisions"]:
            decision["hand"] = []  # Swift重放器根据初始牌和先前走法恢复，原牌张ID保留。
        configurations.append({
            "seed": round_["seed"], "trumpSuit": round_.get("trump"), "trumpRank": round_["rank"],
            "dealer": round_["dealer"], "initialLeader": round_["initialLeader"],
            "decisions": len(round_["decisions"]), "attackPoints": round_["attackPoints"],
        })
    fingerprint = None
    if current_engine:
        digest = hashlib.sha256()
        files = sorted((root / "Tractor" / "Engine").glob("AIPlayer*.swift"))
        files += [root / "Tractor" / "Engine" / name for name in ("CardComparator.swift", "TrickEvaluator.swift")]
        files += [root / "Tractor" / "Models" / name for name in ("Card.swift", "Deck.swift", "GameState.swift")]
        for file in files:
            digest.update(str(file.relative_to(root)).encode())
            digest.update(file.read_bytes())
        fingerprint = digest.hexdigest()
    filename = f"{batch_id}.json"
    payload = (json.dumps(rounds, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    (destination / filename).write_bytes(payload)
    index["batches"].append({
        "id": batch_id, "label": label, "file": filename,
        "seeds": [r["seed"] for r in rounds], "configurations": configurations,
        "recordSHA256": hashlib.sha256(payload).hexdigest(), "engineSHA256": fingerprint,
    })
    temporary = index_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(index_path)
    print(f"Saved {len(rounds)} rounds: {destination / filename}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--id", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--current-engine", action="store_true", help="仅当记录由当前引擎生成时保存源码指纹")
    arguments = parser.parse_args()
    archive(arguments.source, arguments.id, arguments.label, arguments.current_engine)
