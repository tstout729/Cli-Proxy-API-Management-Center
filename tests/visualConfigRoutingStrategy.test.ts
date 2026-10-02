import { describe, expect, test } from 'bun:test';
import { createElement, useState } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { parse as parseYaml } from 'yaml';
import { parseRoutingStrategy, useVisualConfig } from '../src/hooks/useVisualConfig';

describe('visual config weighted routing strategy', () => {
  test('recognizes the weighted-round-robin backend value', () => {
    expect(parseRoutingStrategy('weighted-round-robin')).toBe('weighted-round-robin');
    expect(parseRoutingStrategy('weightedroundrobin')).toBe('weighted-round-robin');
    expect(parseRoutingStrategy('wrr')).toBe('weighted-round-robin');
    expect(parseRoutingStrategy('fill-first')).toBe('fill-first');
    expect(parseRoutingStrategy('fillfirst')).toBe('fill-first');
    expect(parseRoutingStrategy('ff')).toBe('fill-first');
    expect(parseRoutingStrategy(undefined)).toBe('round-robin');
    expect(parseRoutingStrategy('weekly-reset-first')).toBe('weekly-reset-first');
  });

  test.each(['weighted-round-robin', 'weekly-reset-first'] as const)(
    'preserves %s in YAML',
    (strategy) => {
      function Harness() {
        const visualConfig = useVisualConfig();
        const [phase, setPhase] = useState(0);

        if (phase === 0) {
          visualConfig.setVisualValues({ routingStrategy: strategy });
          setPhase(1);
        } else {
          return createElement(
            'pre',
            null,
            visualConfig.applyVisualChangesToYaml('routing:\n  strategy: round-robin\n')
          );
        }

        return null;
      }

      const markup = renderToStaticMarkup(createElement(Harness));
      const result = markup.slice('<pre>'.length, -'</pre>'.length);

      expect(parseYaml(result)).toEqual({ routing: { strategy } });
    }
  );
});
