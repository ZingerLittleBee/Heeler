// The homepage's entry: the pinned stage, the sections below it, and reveal on scroll.
import { reveal } from '../motion';
import { wireSections } from './sections';
import { wireStage } from './stage';

wireStage();
wireSections();
reveal();
