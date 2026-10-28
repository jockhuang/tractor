# 保存的自对弈种子

`seeds.json`是批次索引，逐局记录种子、主花色、级牌、庄家和初始先手。各批次JSON保存初始牌、底牌、完整逐手走法、公开墩记录和审计标记；重复的决策前手牌从初始牌与走法还原，牌张ID保留。

| 批次 | 用途 |
|---|---|
| `seeds-1501-1510-baseline.json` | 第一轮发现问题时的原始10局。前两局保留旧冒烟测试的先手配置，不能套用现在的庄家先领重新推导。 |
| `seeds-1511-1520-verified.json` | 上一轮修复后验收的10局。 |
| `seeds-1521-1530-review.json` | 新一批10局复核原始记录，包含1526第5墩发现的拔主计划过滤遗漏。 |
| `seeds-1521-1530-verified.json` | 补齐拔主计划过滤后，同样10组发牌的验收记录。 |

目前共保存30个不同种子；1521–1530保留修复前后两个版本，不覆盖原始走法。

## 精确复核单个种子

在`Tractor/`内运行，例如重跑1518：

```sh
TRACTOR_AI_TEST_OPTIMIZE=1 TRACTOR_AI_FULL_ROUND=1 TRACTOR_AI_REPLAY_PATH=AITests/SelfPlay/seeds-1511-1520-verified.json TRACTOR_AI_REPLAY_SEED=1518 ./run_ai_tests.sh
```

省略`TRACTOR_AI_REPLAY_SEED`会重跑该批次全部牌局。可同时设置`TRACTOR_AI_AUDIT_PATH`保存当前策略的新结果；不会修改原批次。

复核新发现的1526第5墩，将路径换成`AITests/SelfPlay/seeds-1521-1530-review.json`，种子换成1526。该批次保留了当时的问题走法；`-verified`批次则保存修复后的完整过程。

重跑使用保存的初始牌、底牌及局面配置，决策使用当前AI。原始逐手记录则可由`SelfPlayAudit.state(before:round:)`恢复任一决策前状态。策略调整后走法可以改变，不应要求与旧记录逐手一致。

不能仅用`TRACTOR_AI_SEED=1518 TRACTOR_AI_ROUNDS=1`代替上述复核：新批次的主花色、级牌和座次从批次索引安排，可能与1518原局不同。

## 保存新批次

```sh
python3 AITests/archive_self_play.py /private/tmp/tractor-self-play.json --id seeds-xxxx-yyyy-review --label '本轮复核说明' --current-engine
```

只有记录确由当前引擎生成时才加`--current-engine`，它会保存引擎源码指纹。归档同时记录文件SHA-256；已有批次ID禁止覆盖，比较策略版本时另存新批次。默认测试会核对种子发牌，并按规则合法重放所有归档记录。
