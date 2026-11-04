import type { APIRoute } from 'astro';
import { createLocaleSearch } from '../../api/search.json.ts';

const server = createLocaleSearch('zh');

export const GET: APIRoute = () => server.staticGET();
