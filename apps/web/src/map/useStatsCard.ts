import { useEffect, useRef, useState } from 'react';
import { getStatsCard } from '../api';
import { statsCardKey, type StatsCardRequest } from './exportStats';

/** How long the request waits after the size, theme or checked set last changed. */
const STATS_CARD_DELAY_MS = 400;

export interface StatsCard {
  /** The request it was drawn for (statsCardKey). */
  key: string;
  /** An object URL of the PNG, for the preview's <img>. */
  url: string;
  /** The decoded PNG, drawn onto the image at its own pixel size. */
  image: HTMLImageElement;
}

export interface StatsCardState {
  /** The card last drawn, held for the preview and Export; null with none to show. */
  card: StatsCard | null;
  /** Whether the held card answers the current request, so Export draws what's previewed. */
  ready: boolean;
  error: string | null;
}

/**
 * The stats card the server draws for [request] (FR-4.10): asked for again after a pause in
 * changing it, and held until the next one arrives, so Export never makes a second request.
 */
export function useStatsCard(request: StatsCardRequest | null): StatsCardState {
  const key = statsCardKey(request);
  const [card, setCard] = useState<StatsCard | null>(null);
  // The request the last answer was for, a card, no card (all Pending) or an error alike.
  const [settled, setSettled] = useState('');
  const [error, setError] = useState<string | null>(null);
  // The effect runs on the key alone; the request it stands for is read from here.
  const latest = useRef(request);
  latest.current = request;

  useEffect(() => {
    const request = latest.current;
    if (!request) {
      setCard(null);
      setError(null);
      return;
    }
    const abort = new AbortController();
    const timer = window.setTimeout(() => {
      getStatsCard(request, abort.signal)
        .then(async (blob) => {
          if (!blob) return null;
          const url = URL.createObjectURL(blob);
          const image = new Image();
          image.src = url;
          await image.decode();
          return { key, url, image };
        })
        .then((next) => {
          if (abort.signal.aborted) {
            if (next) URL.revokeObjectURL(next.url);
            return;
          }
          setCard(next);
          setError(null);
          setSettled(key);
        })
        .catch((err: unknown) => {
          if (abort.signal.aborted) return;
          setCard(null);
          setError(err instanceof Error ? err.message : String(err));
          setSettled(key);
        });
    }, STATS_CARD_DELAY_MS);
    return () => {
      window.clearTimeout(timer);
      abort.abort();
    };
  }, [key]);

  // A card replaced or dropped gives back its URL.
  useEffect(() => {
    if (!card) return;
    return () => URL.revokeObjectURL(card.url);
  }, [card]);

  return { card: request ? card : null, ready: !request || settled === key, error: request ? error : null };
}