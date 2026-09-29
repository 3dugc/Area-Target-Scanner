# Immersal 扫描上传格式与 All.zip 核查

核查日期：2026-09-29。依据为 Immersal 官方文档、官方示例、本地 `All.zip` 和当前 `develop` 工作区代码。本次只做本地检查与公开资料查询，未上传扫描数据，也未验证云端建图结果。

**结论**

`All.zip` 与 Immersal Mapper 的图像和元数据导出结构相符，具备通过 Capture API 提交的逐帧数据。需要上传程序解包、加入账号凭据并组装 API 请求；它不是一个可直接 POST 到 `/capture` 的 ZIP 请求体。公开 Portal 文档未明确说明整包 ZIP 的导入入口，因此“网页直接拖入 ZIP”仍待界面验证。官方 [Map Testing](https://developers.immersal.com/docs/mapsmapping/advanced/maptestingfeature/) 明确描述 Mapper 导出 ZIP，解压得到 PNG 和 JSON；[Portal 文档](https://developers.immersal.com/docs/mapsmapping/developerportal/)主要描述地图管理和下载。

本项目原有 `ios_scanner` ZIP 与之不同，但包含转换所需的图片、逐帧位姿和内参。现已增加独立 Immersal 导出适配，详见 [双格式导出说明](ios-dual-export.md)。反方向，`All.zip` 不能直接用于本项目现有网页处理管线。

**1. All.zip 的实际检查结果**

| 检查项 | 结果 |
|---|---|
| 文件总数 | 550：275 个 PNG，275 个 JSON |
| 组织方式 | ZIP 根目录，每张图片与 JSON 同名 |
| 图像格式 | 全部为 1920 × 1440、8 位通道的 RGB PNG（24-bit RGB） |
| 会话与序号 | 一个 `run`；`index` 为 0–274，无重复或缺号 |
| 配对 | 275 个 `imagePath` 均指向存在的图片，与 JSON 文件名对应 |
| JSON | 全部可解析，字段集合一致，数值均有限，焦距为正，主点位于图像内 |
| 旋转矩阵 | 正交误差最大约 7.42 × 10⁻⁷；行列式约为 1 |
| anchor | 全部为 false；不指定显式锚点并不构成格式错误 |
| GPS | 每帧包含经纬度和海拔；本文不复述实际地理位置 |
| 凭据 | JSON 不含 developer token |
| ZIP 完整性 | 所有条目 CRC 检查通过 |
| 大小 | 压缩约 582 MiB；解压内容 747,117,111 字节，约 713 MiB |

这些检查说明数据结构和基础数值合理，不能证明每帧位姿与图像真实对应，也不能证明图像清晰度、覆盖率、云端建图或定位质量。旋转矩阵合法也不等于坐标方向正确。

**2. 建议采用的本地扫描交换格式**

对当前手机扫描场景，采用每帧一张 PNG 加一份 JSON，必要时用 ZIP 归档：

```text
scan.zip
├── frame_0000.png
├── frame_0000.json
├── frame_0001.png
├── frame_0001.json
└── ...
```

UUID 文件名与顺序文件名均可用于这种本地组织方式。同名配对便于检查；官方 [encode_images_and_json.py](https://github.com/immersal/immersal-python-tools-for-customer/blob/main/utils/encode_images_and_json.py) 实际通过 JSON 中的 `imagePath`、相对于 JSON 所在目录寻找图片。此字段是本地关联信息，不替代 API 请求中的图像字节。该官方脚本用于测试数据编码，不是已经执行的建图上传操作。

下面是自拟的结构示例，数值仅示意，实际导出必须使用每帧真实数据：

```json
{
  "imagePath": "frame_0000.png",
  "run": 1,
  "index": 0,
  "anchor": false,
  "fx": 1340.0,
  "fy": 1340.0,
  "ox": 960.0,
  "oy": 720.0,
  "px": 0.0,
  "py": 0.0,
  "pz": 0.0,
  "r00": 1.0, "r01": 0.0, "r02": 0.0,
  "r10": 0.0, "r11": 1.0, "r12": 0.0,
  "r20": 0.0, "r21": 0.0, "r22": 1.0,
  "latitude": 0.0,
  "longitude": 0.0,
  "altitude": 0.0
}
```

| 字段 | 含义与约束 |
|---|---|
| `imagePath` | 本地图片相对路径；上传器读取对应图片后不依赖服务器访问本地路径 |
| `run` | 整数，会话标识；同一连续坐标空间保持一致，坐标重置或新会话时更换 |
| `index` | 整数，帧顺序；保留原始顺序，不根据 UUID 字典序重编号 |
| `anchor` | 布尔值，是否指定地图锚点；无需显式锚点时可为 false |
| `fx`, `fy` | 该帧图像的焦距，单位为像素 |
| `ox`, `oy` | 该帧图像的主点坐标，单位为像素，对应本项目的 `cx`, `cy` |
| `px`, `py`, `pz` | 相机位姿的位置分量，使用一致的米制空间 |
| `r00`…`r22` | 相机姿态的 3×3 旋转矩阵；不是欧拉角或四元数 |
| `latitude`, `longitude`, `altitude` | 地理位置；官方示例对无 GPS 数据使用 0 值 |

上述字段含义参考 [Custom Images](https://developers.immersal.com/docs/mapsmapping/advanced/custom-images/)；无 GPS 时的具体示例见 [Python Examples](https://developers.immersal.com/docs/rest-api/python-example/)。PNG 是本次核对到的 Capture 文档明确列出的图像格式，可使用 8 位灰度或 24 位 RGB。不要因其他接口支持 JPEG 就把它当作本接口已经验证的格式。

**3. 真正发给 Immersal 的请求格式**

| 上传路径 | 请求体 |
|---|---|
| `POST https://api.immersal.com/capture` | UTF-8 JSON 元数据字节 + 一个 `0x00` 分隔字节 + PNG 文件字节 |
| `POST https://api.immersal.com/captureb64` | JSON 元数据，增加 `b64` 字段存放 PNG 的 Base64 字符串 |

两种方式均在请求中加入有效 `token`；本地扫描包无需保存凭据。逐帧上传成功后，调用 `/construct` 并提供地图名和 `preservePoses` 设置，才会开始建图。`preservePoses` 是否启用取决于位姿质量，不能仅凭 JSON 字段齐全决定。参考 [REST API](https://developers.immersal.com/docs/rest-api/)。

流程为：本地读取 ZIP → 按 `run/index` 组织帧 → 读取 JSON 指向的 PNG → 提交逐帧请求并检查结果 → 发起建图 → 在 Portal 查看处理结果。

上传器应让用户明确选择工作区处理方式；官方示例中的 `/clear` 会删除工作区图片，不能把它作为无提示的默认步骤。此次研究没有调用这些接口。账号配额、图片数量限制和服务器实际接收结果仍需上传时验证。

普通图像建图不要求提交 OBJ、MTL、GLB 或本项目的 `features.db`。另有 Leica BLK2GO 专用的 `.b2g` 上传接口，文档注明需要 Pro 或 Enterprise 权限；它不适用于当前 PNG+JSON 包。Portal 下载的 `.bytes` 是建图后供 SDK 定位使用的地图产物，与原始扫描输入不同。[REST API](https://developers.immersal.com/docs/rest-api/)、[Portal 输出说明](https://developers.immersal.com/docs/mapsmapping/developerportal/)

**4. 与本项目扫描器的字段对应**

| 本项目 `manifest.json` / 图片 | Immersal 导出适配 |
|---|---|
| `frames[i].imageFile` → JPEG | 解码并编码为 PNG，写入对应 `imagePath` |
| `frames[i].index` | `index` |
| `frames[i].intrinsics.fx/fy` | `fx/fy` |
| `frames[i].intrinsics.cx/cy` | `ox/oy` |
| `frames[i].transform` | 拆出位置和旋转，再核对相机坐标约定 |
| `frames[i].run`、`location`（新增可选字段） | 持久化会话编号与拍摄时定位；`anchor` 固定 false |
| 模型、点云、材质 | 保留供本项目使用，不作为普通 Capture 图像请求的必要部分 |

项目实际按列主序保存 ARKit 4×4 相机到世界变换。对数组 `a`，原始矩阵元素的拆解是：

```text
px = a[12], py = a[13], pz = a[14]

R = [ a[0]  a[4]  a[8]  ]
    [ a[1]  a[5]  a[9]  ]
    [ a[2]  a[6]  a[10] ]
```

这只是现有数组布局的解释。新增导出器采用 `RImmersal = RARKit × diag(1,-1,-1)`、位置不变，并使用独立双精度投影测试验证本地合同，详情及真机验证状态见 [双格式导出说明](ios-dual-export.md)。REST 文档使用 row matrix 的措辞，Custom Images 页使用 column-major 的措辞；API 字段又明确以 `r行列` 命名。实现时应以矩阵元素、相机坐标基和图像朝向共同验证，不能仅凭措辞随意转置或翻轴。

本项目直接编码 ARKit 原始图像缓冲区，未旋转像素，导出方向记为 `landscapeRight`。若适配时缩放、裁剪或旋转图片，必须同步变换内参，必要时调整相机旋转。只有纯编码转换且保持尺寸和像素方向时，内参才可原值保留。应先用少量具有已知位置与朝向的帧检查尺度和朝向，再验证一段实际扫描建图。

代码依据：

- [ScanDataExporter.swift](../ios_scanner/AreaTargetScanner/Services/ScanDataExporter.swift)：`exportManifest` 写入逐帧 schema。
- [CameraPose.swift](../ios_scanner/AreaTargetScanner/Models/CameraPose.swift)：列主序位姿序列化。
- [ARKitScannerService.swift](../ios_scanner/AreaTargetScanner/Services/ARKitScannerService.swift)：图像方向、逐帧内参及 ARKit 位姿采集。

**5. All.zip 能否直接传给本项目网页**

不能，存在两个独立原因：

1. [web_service/app.py](../web_service/app.py) 的 `safe_extract` 限制解压总大小为 500 MiB，当前包约 713 MiB。
2. 网页必须找到同目录的 `model.obj` 与 `poses.json`；[optimized_pipeline.py](../processing_pipeline/optimized_pipeline.py) 还要求 `model.mtl` 与 `texture.jpg`。`All.zip` 只有图片和逐帧 JSON，缺少这些文件。

只转换 JSON 或调高大小上限仍不足以兼容：还需从图像重建网格和纹理，或改造处理管线支持另一类输入。扫描器新增的“Immersal PNG+JSON 导出”模式利用已有逐帧数据，保留原项目格式并独立适配。
