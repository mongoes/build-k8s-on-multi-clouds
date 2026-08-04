# health-check 存储检查相关 YAML 导出

导出自 `ta-admin-manager` (release/6.0)，围绕 `StorageHealthChecker` 的 te-disk / te-nfs 检查。

## 目录结构

```
health-check-yaml/
├── README.md                          ← 本文件
├── probe(health-check生成)/            ← ★ health-check 运行时动态生成的探测资源(还原版,可直接 apply)
│   ├── probe-te-disk.yaml             块存储探测: PVC(RWO) + Pod,等 Bound + Pod Ready
│   └── probe-te-nfs.yaml              网络存储探测: PVC(RWX) + Pod,只等 Bound
├── block-sc/                          ← te-disk 各云 StorageClass 模板(有强云平台特征)
│   ├── te-disk-sc.ali.yaml            阿里云  diskplugin.csi.alibabacloud.com
│   ├── te-disk-sc.aws.yaml            AWS    ebs.csi.aws.com
│   ├── te-disk-sc.google.yaml         GCP    pd.csi.storage.gke.io
│   ├── te-disk-sc.huawei.yaml         华为云  everest-csi-provisioner
│   ├── te-disk-sc.onprem.yaml         私有化  driver.longhorn.io
│   ├── te-disk-sc.tencent.yaml        腾讯云  com.tencent.cloud.csi.cbs
│   └── te-disk-sc.volcengine.yaml     火山引擎 ebs.csi.volcengine.com
├── nfs-sc/                            ← te-nfs StorageClass 模板
│   └── te-nfs-sc.aws.yaml             AWS EFS(仅 AWS 有静态模板,含 fileSystemId)
└── nfs-provisioner/                   ← 自建 NFS server(Helm),private 部署常用
    ├── values.yaml                    Helm values,storageClass.create=true,SC 名默认 nfs-provisioner
    ├── pvc-nfs-skills.yaml            业务共享 PVC(RWX 20Gi)
    └── pvc-nfs-share.yaml             业务共享 PVC(RWX,大小可配)
```

## 关键结论

1. **探测 PVC 完全通用,无云平台特征**：只引用 `storageClassName` + accessMode + 容量。
   云差异全部下沉到 StorageClass 层（provisioner 不同）。

2. **te-disk vs te-nfs 探测的唯一实质差异**：
   - te-disk: `ReadWriteOnce`(RWO,单节点)+ 等 PVC Bound + **等 Pod Ready**
   - te-nfs:  `ReadWriteMany`(RWX,多节点)+ 只等 PVC Bound

3. **te-nfs 的两条创建路径**（health-check 不创建,只消费）：
   - `te_k8s install -name csi`：AWS=套 te-nfs-sc.yaml 模板(需 file-system-id)；华为=从 csi-sfs 拷贝；其它云无。
   - `te_k8s install -name nfs-provisioner`：Helm 自建 NFS server,默认 SC 名为 `nfs-provisioner`。

## 模板占位符说明

导出的模板保留了源码中的占位符,实际部署时被替换：
- `<ts>`             : 毫秒时间戳(探测资源唯一名,代码中 System.currentTimeMillis())
- `${file-system-id}`: AWS EFS 文件系统 ID(用户输入)
- `${pvc.storageClass}` `${pvc.dataSize}` `${resources.limits.*}` `${storageClassName}` : 由 install.properties 注入
