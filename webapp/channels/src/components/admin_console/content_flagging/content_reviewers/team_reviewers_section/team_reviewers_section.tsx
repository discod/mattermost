// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import React, { useCallback, useEffect, useMemo } from "react";
import {useIntl} from 'react-intl';
import {useDispatch} from 'react-redux';

import type { Team, TeamSearchOpts, TeamsWithCount } from "@mattermost/types/teams";

import { getTeams, searchTeams } from "mattermost-redux/actions/teams";
import type { ActionFuncAsync, ActionResult } from "mattermost-redux/types/actions";

import DataGrid from 'components/admin_console/data_grid/data_grid';
import Toggle from 'components/toggle';
import {TeamIcon} from 'components/widgets/team_icon/team_icon';

import * as Utils from 'utils/utils';

import {UserMultiSelector} from '../../user_multiselector/user_multiselector';

import './team_reviewers_section.scss';

const GET_TEAMS_PAGE_SIZE = 10;

export default function TeamReviewers(): JSX.Element {
    const intl = useIntl();
    const dispatch = useDispatch();

    const [page, setPage] = React.useState(0);
    const [total, setTotal] = React.useState(0);
    const [startCount, setStartCount] = React.useState(1);
    const [endCount, setEndCount] = React.useState(100);

    const [teamSearchTerm, setTeamSearchTerm] = React.useState<string>('');

    const [teams, setTeams] = React.useState<Team[]>([]);

    const setPaginationValues = useCallback((page: number, total: number) => {
        const startCount = (page * GET_TEAMS_PAGE_SIZE) + 1;
        const endCount = Math.min((page + 1) * GET_TEAMS_PAGE_SIZE, total);

        setStartCount(startCount);
        setEndCount(endCount);
    }, []);

    useEffect(() => {
        const fetchTeams = async (term: string) => {
            try {
                // const teamsResponse = await dispatch(getTeams(page, GET_TEAMS_PAGE_SIZE, true, false)) as ActionResult<{teams: Team[]; total_count: number}>;
                const teamsResponse = await dispatch(searchTeams(term || '', {page, per_page: GET_TEAMS_PAGE_SIZE} as TeamSearchOpts));

                if (teamsResponse && teamsResponse.data) {
                    setTotal(teamsResponse.data.total_count);

                    if (teamsResponse.data.teams.length > 0) {
                        setTeams(teamsResponse.data.teams);
                    }

                    setPaginationValues(page, teamsResponse.data.total_count);
                }
            } catch (error) {
                console.error(error);
            }
        };

        // const searchTeams = async (term: string) => {
        //     try {
        //         const teamsResponse = await dispatch(searchTeam(page, GET_TEAMS_PAGE_SIZE, true, false)) as ActionResult<{teams: Team[]; total_count: number}>;
        //
        //         if (teamsResponse && teamsResponse.data) {
        //             setTotal(teamsResponse.data.total_count);
        //
        //             if (teamsResponse.data.teams.length > 0) {
        //                 setTeams(teamsResponse.data.teams);
        //             }
        //
        //             setPaginationValues(page, teamsResponse.data.total_count);
        //         }
        //     } catch (error) {
        //         console.error(error);
        //     }
        // };

        fetchTeams(teamSearchTerm);
    }, [dispatch, page, setPaginationValues, teamSearchTerm]);

    const columns = useMemo(() => {
        return [
            {
                name: intl.formatMessage({id: 'admin.contentFlagging.reviewerSettings.header.team', defaultMessage: 'Team'}),
                field: 'team',
                fixed: true,
            },
            {
                name: intl.formatMessage({id: 'admin.contentFlagging.reviewerSettings.header.reviewers', defaultMessage: 'Reviewers'}),
                field: 'reviewers',
                fixed: true,
            },
            {
                name: intl.formatMessage({id: 'admin.contentFlagging.reviewerSettings.header.enabled', defaultMessage: 'Enabled'}),
                field: 'enabled',
                fixed: true,
            },
        ];
    }, [intl]);

    const rows = useMemo(() => {
        return teams.map((team) => ({
            cells: {
                id: team.id,
                team: (
                    <div className='TeamReviewers__team'>
                        <TeamIcon
                            size='xxs'
                            url={Utils.imageURLForTeam(team)}
                            content={team.display_name}
                            intl={intl}
                        />
                        <span className='TeamReviewers__team-name'>{team.display_name}</span>
                    </div>
                ),
                reviewers: (
                    <UserMultiSelector
                        id={`team_content_reviewer_${team.id}`}
                    />
                ),
                enabled: (
                    <Toggle
                        id={`team_content_reviewer_toggle_${team.id}`}
                        ariaLabel={intl.formatMessage({id: 'admin.contentFlagging.reviewerSettings.toggle', defaultMessage: 'Enable or disable content reviewers for this team'})}
                        size='btn-md'
                        onToggle={() => {}}
                    />
                ),
            },
        }));
    }, [intl, teams]);

    const nextPage = useCallback(() => {
        if ((page * GET_TEAMS_PAGE_SIZE) + GET_TEAMS_PAGE_SIZE < total) {
            setPage((prevPage) => prevPage + 1);
        }
    }, [page, total]);

    const previousPage = useCallback(() => {
        if (page > 0) {
            setPage((prevPage) => prevPage - 1);
        }
    }, [page]);

    const setSearchTerm = useCallback((term: string) => {
        setTeamSearchTerm(term);
        setPage(0); // Reset to first page on new search
    }, []);

    const disableAllBtn = useMemo(() => (
        <div className='TeamReviewers__disable-all'>
            <button
                data-testid='copyText'
                className='btn btn-link icon-close'
                aria-label={intl.formatMessage({id: 'admin.contentFlagging.reviewerSettings.disableAll', defaultMessage: 'Disable for all teams'})}
            >
                {intl.formatMessage({id: 'admin.contentFlagging.reviewerSettings.disableAll', defaultMessage: 'Disable for all teams'})}
            </button>
        </div>
    ), [intl]);

    return (
        <div className='TeamReviewers'>
            <DataGrid
                rows={rows}
                columns={columns}
                page={page}
                startCount={startCount}
                endCount={endCount}
                loading={false}
                nextPage={nextPage}
                previousPage={previousPage}
                total={total}
                onSearch={setSearchTerm}
                extraComponent={disableAllBtn}
                term={teamSearchTerm}
            />
        </div>
    );
}
