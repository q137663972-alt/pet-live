# pet-live

7paws 风格桌面猫的**热更新包**仓库：外观包（looks）与功能清单（feats），以及猫舍页面（cattery）。

## 结构

- `manifest.json` 版本清单，客户端据此判断是否需要更新
- `looks/*.json` 外观包：`kind=builtin` 引用 7paws 内置毛色，`kind=custom` 是参数化自造猫
- `feats/ops.json` 功能清单：只声明能力与参数，实际执行由客户端内置 handler 白名单负责
- `cattery/` 猫舍页面资源

## 客户端读取

- 大陆推荐：`https://cdn.jsdelivr.net/gh/q137663972-alt/pet-live@main/manifest.json`
- 直连：`https://raw.githubusercontent.com/q137663972-alt/pet-live/main/manifest.json`

## 规则

1. 外观包随时可改，不影响客户端稳定
2. 功能清单只增删声明，不引入可执行脚本
3. 任何包都必须带 `id` 与 `version`，客户端校验失败会回滚到上一版
