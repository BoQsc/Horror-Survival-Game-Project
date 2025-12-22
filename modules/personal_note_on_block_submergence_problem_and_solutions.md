person_note_on_block_submergence_problem_and_solutions.md

This is a note for auto-mode of building blocks placement. (modules\world_player\api\building_api.gd)

I think future upgrade would be to have no/minimal (80% submergence allowed, after that place block above and use terrain tool to match terrain to block bottom) building block submergence and use terrain tool to automatically adjust terrain to match the block.

We should document this as future possibility of improvement. It is more logical to not autoexcavate, but we have no choice to either autoexcavate (allowing submergence) or filling space with terrain to the block.

Again this might lead to exploitation, if you just place block and terrain grows, you remove block and it still stays, then player can just harvest material/terrain forever.
So this is more complex approach.
If we allow submergence, this might be less complex, it simply places block in submergence, but logically less pleasing: the player is suppose to excavate/dig it shouldn't be allowed to just place blocks in the terrain.

