import { useAuth } from '../auth/AuthContext';

export type UnitSystem = 'metric' | 'imperial';

/** A hook, not a prop threaded through every component that formats a distance — every
 *  caller reaches this directly via `useAuth()`, avoiding prop-drilling through chains like
 *  `MapView → ActivitiesPanel → DistanceFilter` for a value that only ever changes when the
 *  Settings page saves a new Country. The server decides it from the Country (the Account's
 *  `unit_system`, services/server/internal/web/format.go's Imperial). */
export function useUnitSystem(): UnitSystem {
  const { user } = useAuth();
  return user.unitSystem;
}
