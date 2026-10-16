// src/utils/webApiBase.ts
// 当前文件：把同源 `/api/*` 请求转发到用户配置的 Folia 后端。
//
// Web / Vercel / Electron 构建不设置 base 时这里完全是 no-op，行为与原实现一致。
// 只有把前端打包成静态资源时（Capacitor iOS 的页面来源是 capacitor://localhost，站内不再自带
// `/api` 服务端函数），才需要把 base 指向一个已部署的 Folia 后端。
//
// 配置优先级：window.__FOLIA_RUNTIME_CONFIG__.webApiBase > 构建期环境变量 VITE_FOLIA_API_BASE。

const normalizeWebApiBase = (value: unknown): string => (
    typeof value === 'string' ? value.trim().replace(/\/+$/, '') : ''
);

/** 当前生效的后端 base；未配置时返回空串，表示继续按同源相对路径请求。 */
export const getWebApiBase = (): string => {
    if (typeof window !== 'undefined') {
        const runtimeBase = normalizeWebApiBase(window.__FOLIA_RUNTIME_CONFIG__?.webApiBase);
        if (runtimeBase) return runtimeBase;
    }
    const envValue = (import.meta as ImportMeta & { env?: Record<string, string> }).env?.VITE_FOLIA_API_BASE;
    return normalizeWebApiBase(envValue);
};

/** 把同源 `/api/*` 路径改写成绝对地址；未配置 base、或不是 `/api/*` 时原样返回。 */
export const resolveWebApiUrl = (url: string): string => {
    const base = getWebApiBase();
    if (!base || !url.startsWith('/api/')) return url;
    return `${base}${url}`;
};

/**
 * 安装 fetch 转发：把代码里所有 `fetch('/api/...')` 指向配置的后端。
 *
 * 只改写字符串形式的同源 `/api/*` 请求，其他请求原样交给原生 fetch，因此未配置 base 时
 * 不产生任何行为差异。安装在渲染前（src/index.tsx），保证首个网络请求之前就已经生效。
 */
export const installWebApiBaseShim = (): void => {
    if (typeof window === 'undefined' || typeof window.fetch !== 'function') return;
    if (getWebApiBase() === '') return;

    const originalFetch = window.fetch.bind(window);
    window.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
        if (typeof input === 'string') {
            return originalFetch(resolveWebApiUrl(input), init);
        }
        return originalFetch(input, init);
    }) as typeof window.fetch;
};
