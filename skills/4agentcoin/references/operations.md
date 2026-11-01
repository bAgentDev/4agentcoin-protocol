# 4AgentCoin Agent 工作量证明操作参考

产品定位为 Agent 工作量证明（Agent Proof of Work）：Agent 完成工作任务、提交工作证明，合约验证工作结果并发放有效工作奖励。本地V1业务合约为GenesisMiner、MiningPool、FourAgentCoin。下述ABI名称对应本地源码，生产使用前必须匹配编译产物、代码和绑定。没有已核实的生产部署清单；项目身份适配器接口不是已核实的官方Registry ABI。缺必要配置就报告未开放，不编造交易。

## 操作入口与支持边界

同一份 Skill 覆盖资产和矿机查询、铸造、批量质押/解押、工作任务、NFT 转移和市场、4AGC 转账与买卖。用户用自然语言提出请求，Agent 按本参考选择真实合约调用及官方 BAW 能力；无需为每项业务另装一份 Skill。这不等于包内每项业务都有命令行实现，也不代表安装完成后已有生产地址、官方身份适配器、钱包授权或交易流动性。

查询资产时，读取官方钱包余额和已核实合约中的矿机所有权、HP、质押及有效订单。按用户请求限定链与钱包，不先索取 Agent ID；不能用本机运行器的 `status` 冒充完整资产查询。网页功能入口和显示开关不会改变合约权限；swap 链接可见也不证明已有可交易的流动性。

### 真正的包内 CLI

| 命令 | 实际作用 |
|---|---|
| `node scripts/agent-miner.mjs --help` | 查看运行器用法。 |
| `node scripts/agent-miner.mjs status --config miner.local.json` | 只读核验配置和部署，读取该 NFT 当前任务、历史会话与原交易回执。 |
| `node scripts/agent-miner.mjs dry-run --config miner.local.json` | 与 status 一样只读，不调模型、不做钱包 preview、不模拟或广播交易。 |
| `node scripts/agent-miner.mjs run --config miner.local.json` | 对一台已质押 NFT，使用 Codex CLI 模型，在已授权边界内完成单项或有限连续工作。 |

`npm run miner -- <模式> --config miner.local.json` 是同一脚本的 npm 入口。包内没有 mint、stake、unstake、transfer、list、buy、cancel、swap 或 stop 子命令，也没有对应斜杠指令。铸造、批量质押和其他资产操作由 Agent 依本参考组织调用，不是运行器代办的前置步骤。运行器不支持多 NFT 轮转或其他模型宿主；目前未完成真实付费模型和 BAW 广播的端到端验收，不能声称已通过生产使用验证。

## 部署与运行器

### 身份与核验

读取RPC chain ID、完整地址、代码和匹配ABI。GenesisMiner、MiningPool 使用 UUPS/ERC1967 代理，业务地址始终使用代理地址；同一区块核对代理运行时代码 hash、标准 ERC1967 implementation slot 中的地址及已审阅的 implementation 代码 hash，不能仅凭代理 hash 未变认定逻辑未变。FourAgentCoin 保持固定合约，发奖后的 miningPool 绑定锁仍指向稳定的 Pool 代理。`GenesisMiner.identityVerifier()`返回项目适配器，其 `isEligible(address)` 与 `agentIdOf(address)->bytes32` 定义项目接口。另核实官方Registry的出处、链、真实ABI、资格和稳定ID语义，以及adapter真实绑定。钱包品牌、CLI声明或普通签名不证明资格。

各代理通过 Ownable2Step owner 控制管理与 UUPS 升级，没有独立 ProxyAdmin；部署人、管理员和 LP 资金账户可以是普通 EOA，不因这些角色要求 Agent ID。owner 能改变 NFT/矿池实现，固定 Token cap 不保证矿池排放规则不可变；本次采用的数值与经济规则不变。管理员升级后须重新审阅实现与权限，不能自动把运行配置替换成链上新实现或沿用旧实现的工作授权。提交前复核也不能锁住待确认期间的管理员升级。

官方资格适用于公开mint、新质押、每次提交工作证明。新质押绑定稳定Agent ID，身份撤销或变更阻止新的工作证明/质押，仍可退出、NFT市场、转移、代币操作和查历史。尽量在同一已知区块读取所有权、HP、质押、nonce、奖励和订单，交易前复读；价格变化用minGross/expectedPrice等链上条件保护。

### 配置和命令

安装入口见[Skill主文档](../SKILL.md#安装与公开源码)。首次需要运行器时，由 Agent 在已安装 Skill 目录执行 `npm ci --ignore-scripts` 安装锁定依赖；依赖已就绪时不重复安装，无需用户每次手工处理。复制包内 `assets/miner-config.example.json` 为 `miner.local.json`。禁止放私钥、provider token或BAW会话。

| 配置 | 要求 |
|---|---|
| environment/chainId/rpcUrl | 明确环境和真实RPC；RPC URL不能含用户名/密码 |
| walletAddress/poolAddress/genesisAddress/tokenAddress/tokenId | 完整实际地址，tokenId为NFT uint256，不是bytes32 Agent ID |
| deployment.verified/identityVerifier/codeHashes | pool/genesis 为代理运行时代码keccak256，token/identityVerifier 为现有固定Token/adapter代码hash；同时核验合约互绑、16/4常量、六位HP、18位4AGC与3%任务费 |
| deployment.proxies.genesis / deployment.proxies.pool | 每项均必需 implementationAddress、implementationCodeHash；来自已独立审阅的实际实现，不能为未知升级自动填值。读取标准ERC1967 slot并在同一区块核地址、实现代码与代理代码；空slot、非合约实现、缺值或不匹配均阻断新的工作 |
| deployment.localMocks | 只可在明确local、31337为true；只用于read/dry-run和注入测试，官方BAW不签本地链 |
| deployment.verifiedIdentitySource | live必需：verified、chainId、officialUrl、verifiedAt、verificationEvidence、registryAddress、registryCodeHash及adapterRegistryRead的实际abi/functionName。该读取必须来自真实adapter ABI，无参只读返回address；回链核对Registry绑定，不能猜getter |
| model | 只实现provider=codex；真实binary、automationAuthorized=true、timeoutMs为1000–600000、maxAttempts为1–3 |
| authorization | 用户明确确认后生成并记录唯一consentId(UUID)、confirmedByUser、single/bounded、poolAddress/chainId/walletAddress/tokenId、maxTasks、maxDurationSeconds、maxGasWei、maxGasPerTaskWei、正数minGrossWei、ISO格式expiresAt；缺项不能run |
| skipRepeatedConfirmations | 仅用户明确跳过重复确认且授权覆盖此有界循环才设true；不授权其他资金动作 |
| stateFile | 只记录本机进度和请求hash，不存凭据，默认.miner-state/session.local.json，不打包 |

缺配置时 status/dry-run 返回 stopped，不猜地址。`run`还核实官方BAW已连接、链受支持和配置钱包为当前钱包。初次运行按官方Skill完成版本/登录preflight。运行配置以包内[配置示例](../assets/miner-config.example.json)为起点，ABI与代码按[公开合约源码](https://github.com/bAgentDev/4agentcoin-protocol/tree/main/contracts/src)的编译产物及真实部署核验；示例不启用执行，不能仅把verified改为true。

单项工作mode=single且maxTasks=1；持续mode=bounded，上限1000项工作和24小时，可给更低限制。必须先有明确模型宿主与预算。授权绑定池、链、钱包、NFT和两份已审阅的实现地址/hash；重启同一consentId保留已耗时和gas，不因JSON键序、备注等无意义变化重置；同consentId修改范围、预算或审核实现会拒绝。旧格式状态没有实现指纹时须保留其预算和待决记录并重新审阅授权，不能清记录绕过。只有用户明确授予新的consentId才开启新预算，不得由Agent自动改ID续费。进程退出不会自动保活。

每轮模型前、wallet preview前和execute前都重新核验代理实现、业务绑定与当前任务；nonce相同也不豁免实现核验。`status`/`dry-run`发现部署或实现不匹配时返回`deploymentError`，仍在原配置链读取保存的原交易/替换交易回执，不调用模型或钱包，不把历史成功当作当前仍在运行。

gas守卫按RPC estimateGas×gasPrice×2预留，检查每次工作和剩余预算，回执后按真实gas累计。官方contract-call不支持gasPrice/maxFee，这不是网络费绝对硬上限；需要不可超出硬上限时应停止，不能宣称脚本可保证。预算耗尽、权限/任务变化、模型错误、钱包确认、预览错误或超时即停。

状态如实区分thinking、waitingapproval、pending、success、stopped；仅模型实际运行时展示thinking。首笔有效工作的成功回执和匹配TaskSolved事件后，才报告“已开始挖矿”。持续循环确实运行时报告“挖矿中”，并标注正在工作（thinking）、等待签名（waitingapproval）或待确认（pending）；循环停止必须明确报告“已停止”，不能继续称“挖矿中”。status/dry-run或历史成功记录不证明循环仍在运行，不能单凭历史成功称“挖矿中”。execute前持久化待处理记录，防止崩溃后自动重发；原hash和预算保存在仅本机状态。单状态文件用锁避免并发，异常残锁先确认旧进程已结束及原请求状态，再人工清锁。未决请求先核对原hash/订单与真实支出，明确重新授权并整理记录，不能删除记录试图重发。

### 停止本机工作

“停止工作”是对 Agent 已启动的本次本机进程的指令，不是运行器的 `stop` 子命令或链上调用。识别对应会话后停止运行器及仍在运行的本次模型子进程，不终止其他作业；停止状态未核实时不能报告已停止。不要再为该会话启动新任务或自动换 consentId 续跑。

停止进程不撤销已经签名或广播的交易，不解押 NFT，也不撤销钱包授权。保留会话、预算和待决记录，用 status 或官方钱包查询原 hash/订单；交易结果未明时不重复 execute。用户若另要求解押，按解押流程处理，不能把停止本机工作扩大成资产操作。

### 模型协议

工作证明只表示提交的工作结果通过链上约束验证，不能证明结果来自LLM或特定模型，也不能阻止程序生成有效结果；不得宣称证明了模型来源或智能。

用户已登录且允许自动化的Codex CLI通过 `exec --json --sandbox read-only --ephemeral --ignore-user-config` 在临时空目录运行；禁shell、Apps、插件、浏览器、多Agent等工具。prompt用stdin，`shell:false`；JSONL最终消息须为严格JSON数组的16个0–3整数。参考[官方非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode)与[配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)。不请求API key、不提取登录文件/token，订阅和许可取决于宿主实际规则，不保证免费或无限额度。

当前适配器只核对本机help/features和注入事件测试，未真实消耗用户模型额度；其他宿主尚未实现。只有完整模型消息的格式/约束错误可在maxAttempts内重试；登录、额度、进程错误和超时直接暂停。不换provider、不买额度、不用本地solver。只检查提交的工作结果赋值，不搜索、修复或枚举其他结果。

## 创世铸造与算力

总量21,000，预留2,100、公开18,900。reservedAllocated+publicMinted为分配进度；预留计进度、不计收入，初始不质押，固定150.000000HP。包括管理员的现持有人按相同资格规则质押后可完成工作任务，持有/质押本身没有奖励。

`mintBatch(quantity,salt)` 数量1–21、salt为bytes32；每台0.0021BNB，value=quantity×2100000000000000 wei。先核对mintOpen、剩余总量、余额和稳定Agent ID终身额度：每ID公开累计≤21，转出NFT、换绑钱包不恢复额度。`mint(bytes32)`是一台的兼容入口。

单批1–10台bonusBps=300，11–20为600，21为1000；加成在本批铸造计算前锁定，不是高HP概率，也不是最终HP直接加百分比。偏低分布：Q=1e18，u=entropy%(Q+1)，r=floor(u*u/Q)，adjusted=floor(r*(10000+bps)*Q/(10000*Q+bps*r))，HPmicro=50e6+floor(200e6*adjusted/Q)。最终50–250HP、六位精度。同一稳定ID公开终身结果不重复；碰撞增加1microHP、超过250时回到50继续查重，最多21探测；端点回绕可能大幅降低该结果。预留不参与公开去重。

默认在本机通过系统密码学随机源生成本批32字节salt，例如浏览器 `crypto.getRandomValues(new Uint8Array(32))`。每台公开矿机在同一次铸造交易内、接收合约回调之前固定HP，熵按实际合约定义计算：

```solidity
entropy = keccak256(abi.encode(
    "GENESIS_MINT_POWER_V1", salt, blockhash(block.number - 1), tokenId,
    originalStableId, batchIndex, block.chainid, address(this)
));
```

originalStableId为本次资格查询得到的bytes32稳定ID，batchIndex为从0开始的uint256本批序号。每台独立派生熵，再按上式计算HP和终身去重；不存在VRF请求、订阅充值或第二笔定HP交易。salt本地生成只增加输入变化，不能阻止调用者模拟、挑盐、择时或按结果回滚，区块生产者也能影响区块信息。该低偏曲线不保证实际参与者使用随机盐，不能宣传为不可操纵的公平随机。

`getToken(tokenId)`返回 `(address owner,uint256 power,bool staked,bool isReserved)`；`power/POWER_SCALE`才为HP，POWER_SCALE=1000000。矿机接口没有requestId或powerStatus。已存在的NFT均有固定HP，预留和公开矿机都不能重抽；成功公开铸造后可直接挂牌或按相同资格规则质押。`PublicMinted(minter,tokenId,price)`与`PowerFinalized(tokenId,power)`记录实际结果。

预览展示购机款、salt、可预测风险和gas，确认后execute。salt随calldata固定，但前块hash或已分配编号可能在打包前改变，因此模拟HP不承诺最终值；当前mint接口没有minPower限价参数。必须核对成功回执，再用匹配的PowerFinalized和getToken读取固定HP；未确认的交易按原hash追踪，不能换盐重发。这里删除的是矿机随机请求ID，官方BAW预览的requestId仍须按钱包两步签名流程保留。

## 质押与工作证明

业务batchStake/batchUnstake对应实际Pool `stake(uint256[])`、`unstake(uint256[])`，不是假CLI或同名ABI。新增质押查miningOpen、Genesis.stakingOpen、所有权、固定HP、未质押和官方Agent ID；列全tokenId和HP，不静默删无效项。Pool调用Genesis lock/unlock，用户不能绕过Pool直调。质押锁定期间NFT仍属于原持有人。

unstake对原staker开放，即使工作任务暂停或身份失效；没有待领取时间收益、不扣退出费。解押提升nonce使当前工作任务失效，已到账奖励不丢失。质押/转移使旧挂牌失效。纯质押不发4AGC。

1. `getTask(tokenId)`返回(bytes32 seed,uint256 nonce,uint256 power,uint16[] edges)；每边a=edge>>8,b=edge&255。16对象、4slot、最大degree3保证有解。
2. 用户授权的模型宿主自行推理给16整数。运行器只验证格式/范围/冲突，不用CPU/GPU哈希、贪心、回溯或任何solver代替模型完成工作。
3. 编码packedAnswer=Σ(slot[i]<<(2*i))，第31位以上为0。复读nonce、seed、power及previewReward；任务变化或低于用户minGross就停。
4. 官方BAW preview/确认后 `submitTask(tokenId,expectedNonce,packedAnswer,minGrossReward)`。单交易验证工作证明、有效工作净奖励直接发staker、费发feeRecipient、生成下一项工作任务。无服务器、验收签名或后台收据。
5. 回执成功且匹配池/NFT/staker/原nonce的TaskSolved才算发奖，随后读下一项工作任务。同NFT同区块不能重复提交，等正常回执继续。无21块窗口、无倒计时、无单独claim交易。

4AGC上限21,000,000，初始LP1,050,000，有效工作毛奖励总额度M=19,950,000。第k次减半阈值M−(M>>k)，按提交前累计毛发行量进入阶段，不按天、区块或难度。base=initialBaseReward>>era，gross=min(floor(base×HPmicro/150000000),remaining)。fee=floor(gross×300/10000)，net=gross−fee；3%已在每项有效工作的毛奖励内扣，不再claim。跨阈值的整项工作使用提交前阶段，下一项工作重新读取；零奖励停、可能留尾差。LP和转账不算有效工作奖励发行量。150HP初始每项有效工作2.1仅为可配置本地初值，以真实initialBaseReward/previewReward为准，不代表价格或收益保证。

## 创世矿机市场

NFT市场/转移不要求Agent ID。内置接口 `list(tokenId,priceWei)`、`cancel(tokenId)`、`buy(tokenId,expectedListingId,expectedPrice)`，读getListing/getActiveListings。仅持有人、未质押、HP固定可挂牌；内置市场无需额外NFT全量授权。

买入value必须等于expectedPrice，其余value=0。用户指定最高价时，当前成交价必须不高于该上限，链上expectedPrice仍填写本次核实的精确价格。回链核对seller、listingId、价格、所有权、HP；订单或价格改变需重新预览确认，不自动接受新价。成交BNB内扣5%市场费、向下取整后留在合约并由marketFeeBalance独立记账，余款在同一笔buy中直接支付seller，无需卖家另行领取。1BNB例：买家支付1，卖家直接收到0.95，合约留存市场费0.05。卖家收款失败或买家NFT接收失败，整笔buy回滚，付款、NFT归属、挂牌和市场费记录均不生效，但交易仍消耗gas。挂牌/撤单无协议费、gas另计。

转移用真实ERC721 safeTransferFrom重载，确认from/to/tokenId；approval同样需预览确认，不默认全量/无限授权。已质押先原staker解押。转移不重抽、不恢复mint额度。

创世售款50%LP预算、50%运营；全售39.69BNB，两项各19.845。预算不代表已加池，要核实真实储备和LP归属。管理员市场费和售款分别核算；普通请求不推导管理员划款权限。

## 代币交易与追踪

4AGC持有、转账、swap不要求Agent ID。核实Token、首发PancakeSwap V2 Router/Factory/WBNB/Pair、流动性、系统豁免和LP归属。swap项目税1%，V2 AMM另收0.25%，gas另计；到账token不等于已卖出BNB。

优先官方BAW market-order quote/swap；构命令前读其实际market-order参考并做安全检查。税币兼容的自定义Router调用走External Sign。展示完整输入/输出地址、数量、最小到账、项目税、AMM费、工具费（如有）、gas、滑点、期限；不能猜税币支持。条件买卖用实际限价能力，失败不能静默改立即市价。

转账用官方钱包真实send，按token/decimals确认接收人和数额，不要求身份。查询入口之一为 `baw wallet tx-history --tx <hash> --binanceChainId <chain> --json`。原hash、真实回执和最终资产变化决定成功；App待确认/广播/超时不是成功，不能重复mint、买入或提交工作证明。

## 钱包执行与分发

先读官方[BAW Skill](https://github.com/binance/binance-skills-hub/blob/main/skills/binance-web3/binance-agentic-wallet/SKILL.md)与[External Sign](https://github.com/binance/binance-skills-hub/blob/main/skills/binance-web3/binance-agentic-wallet/references/external-sign.md)。`baw wallet settings --json`核实Developer Mode已启用、未过期；需用户在Binance App的Agentic Wallet管理页→Settings→Developer Mode开启，CLI不能代开。

EVM预览：`baw contract-call preview --binanceChainId <chain> --from <wallet> --to <contract> --value <integerWei> --inputData <hex> --json`。须成功且有有效requestId；展示parsedTx、risks、simulationResult的allowanceChanges/authorityChanges。gas默认钱包估计，不传gasPrice/gasOption；仅用户明确给gasLimit时按官方参数。

用户明确确认后 `baw contract-call execute --requestId <id> --json`。requireConfirmation=false只表示可直接广播，不代表用户确认。过期重新preview并确认；App确认由用户完成，运行器在需要App确认时停在execute之前。PENDING_CONFIRMATION/BROADCASTED都不是链上成功；超时不授权重execute。

官方ZIP与[公开仓的Skill](https://github.com/bAgentDev/4agentcoin-protocol/tree/main/skills/4agentcoin)同源，使用安装命令无需自行打包。两ZIP入口4agentcoin-skill.zip和bagent-skill.zip字节相同，只含Skill、参考、脚本、package/lock、测试和配置示例，排除node_modules、本地配置/状态/日志/key。安装依赖不连接钱包或发交易。自然语言示例见[Skill主文档](../SKILL.md#可以这样说)，按对应业务执行核验与本次授权；只有公开mint、新质押和提交工作要求官方Agent资格。
